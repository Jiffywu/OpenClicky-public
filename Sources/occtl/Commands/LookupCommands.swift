import Foundation
import OpenClickyKit

/// `occtl lookup web|images|places|stock <query>`: runs one lookup through the same tool handler the brain uses.
enum LookupCommands {
    static let usageText = """
        Usage: occtl lookup <web|images|places|stock|status> <query…> [options]
          --count N            results to show
          --fresh day|week|month|year     (web) only recent pages
          --web                (images) whatever a web image search shows, not a photo of the named thing
          --page URL           (images) that page's own preview picture first
          --no-people          (images) skip photos that show people
          --near LAT,LON       (places) search around a point
          --range 1d|5d|1m|3m|1y          (stock) span of the recent closes
          --services FILE      use this services.json instead of the default
          --json               print the tool output the brain would read
        Places use Apple Maps and need no key. Web search, Brave images and quotes need a key: occtl key set <name>.
        """

    static let lookup = OcctlCommand(name: "lookup", usage: "lookup <web|images|places|stock> <query>  run a lookup service") { args in
        var options = LookupOptions.parse(args)
        let config = try ServicesConfig.load(from: options.servicesURL ?? ServicesConfig.defaultURL)
        let services = LookupServices.make(config: config, credentials: CoreCommands.store)

        if options.kind == "status" {
            let issues = config.issues(credentials: CoreCommands.store)
            for service in LookupService.allCases {
                let choice = config.choice(for: service)
                let state = services.isAvailable(service) ? "ready" : (services.hostedWebSearch && service == .webSearch ? "hosted" : "off")
                var line = "\(service.rawValue): \(choice.provider.rawValue) [\(state)]"
                if let reason = services.unavailable[service] { line += "  \(reason)" }
                if let note = services.notes[service] { line += "  note: \(note)" }
                print(line)
                // Problems the line above does not already say (a missing key is already the reason).
                for issue in issues where issue.service == service && !(services.unavailable[service].map { issue.message.contains($0) } ?? false)
                    && !issue.message.contains("occtl key set") {
                    print("  \(issue.severity.rawValue): \(issue.message)")
                }
            }
            return
        }

        guard let (service, toolName) = LookupOptions.service(for: options.kind) else { fail(usageText) }
        guard !options.query.isEmpty || options.page != nil else { fail(usageText) }
        guard services.isAvailable(service) else {
            fail("\(services.unavailableError(service))")
        }
        if let note = services.notes[service] { FileHandle.standardError.write(Data("note: \(note)\n".utf8)) }

        let tools = LookupTools(services: services)
        options.count = options.count.map { max(1, $0) }
        guard let result = await tools.handle(name: toolName, arguments: options.toolArguments(service).jsonString()) else {
            fail("Internal error: \(toolName) is not a lookup tool.")
        }
        if options.json {
            print(result.output)
        } else if let widget = result.widget {
            print(LookupFormatting.text(widget))
        } else {
            let message = (try? JSONValue.parse(result.output))?["message"]?.stringValue ?? result.output
            fail("Lookup failed: \(message)")
        }
        if !result.succeeded { exit(1) }
    }
}

struct LookupOptions {
    var kind = ""
    var query = ""
    var count: Int?
    var freshness: String?
    var web = false
    var page: String?
    var noPeople = false
    var near: (Double, Double)?
    var range: String?
    var servicesURL: URL?
    var json = false

    static func service(for kind: String) -> (LookupService, String)? {
        switch kind {
        case "web": (.webSearch, LookupTools.webSearch)
        case "images", "image", "photos": (.imageSearch, LookupTools.imageSearch)
        case "places", "place": (.places, LookupTools.placeSearch)
        case "stock", "quote", "stocks": (.marketData, LookupTools.stockQuote)
        default: nil
        }
    }

    static func parse(_ args: [String]) -> LookupOptions {
        var options = LookupOptions()
        var words: [String] = []
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value.\n\(LookupCommands.usageText)") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--count", "-n":
                guard let count = Int(value(arg)) else { fail("--count needs a number.") }
                options.count = count
            case "--fresh", "--freshness": options.freshness = value(arg)
            case "--web": options.web = true
            case "--page": options.page = value(arg)
            case "--no-people", "--nopeople": options.noPeople = true
            case "--near":
                let parts = value(arg).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 2 else { fail("--near needs LAT,LON, e.g. --near 37.7749,-122.4194") }
                options.near = (parts[0], parts[1])
            case "--range": options.range = value(arg)
            case "--services": options.servicesURL = URL(fileURLWithPath: (value(arg) as NSString).expandingTildeInPath)
            case "--json": options.json = true
            case "-h", "--help": fail(LookupCommands.usageText)
            default:
                if arg.hasPrefix("--") { fail("Unknown option \(arg).\n\(LookupCommands.usageText)") }
                words.append(arg)
            }
            index += 1
        }
        guard let kind = words.first else { fail(LookupCommands.usageText) }
        options.kind = kind
        options.query = words.dropFirst().joined(separator: " ")
        return options
    }

    /// The tool-call arguments, exactly as a model would send them.
    func toolArguments(_ service: LookupService) -> JSONValue {
        var object: [String: JSONValue] = [:]
        switch service {
        case .webSearch:
            object["query"] = .string(query)
            if let count { object["count"] = .number(Double(count)) }
            if let freshness { object["freshness"] = .string(freshness) }
        case .imageSearch:
            object["query"] = .string(query)
            if web { object["kind"] = "web" }
            if let page { object["page_url"] = .string(page) }
            if noPeople { object["no_people"] = true }
            if let count { object["count"] = .number(Double(count)) }
        case .places:
            object["query"] = .string(query)
            if let count { object["limit"] = .number(Double(count)) }
            if let near {
                object["latitude"] = .number(near.0)
                object["longitude"] = .number(near.1)
            }
        case .marketData:
            object["symbol"] = .string(query)
            if let range { object["range"] = .string(range) }
        }
        return .object(object)
    }
}
