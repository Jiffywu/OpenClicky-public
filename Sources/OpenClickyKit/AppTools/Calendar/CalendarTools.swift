import Foundation

/// A parsed `calendar_find_events` call.
struct CalendarFindRequest: Sendable, Hashable {
    var interval: DateInterval
    var rangeName: String
    var query: String?
    var calendarName: String?
    var includeAllDay: Bool
    var limit: Int
}

/// A parsed `calendar_create_event` call: a new event, a draft made earlier, or a draft id sent along with event
/// details (which may differ from what the user approved, so it is saved only when they match the draft).
enum CalendarCreateRequest: Sendable, Hashable {
    case existingDraft(id: String, confirmed: Bool)
    case revisedDraft(id: String, CalendarNewEvent, confirmed: Bool)
    case new(CalendarNewEvent, confirmed: Bool)
}

struct CalendarNewEvent: Sendable, Hashable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var calendarName: String?
}

/// Word matching for the `query` filter: case- and accent-insensitive, ignoring filler words.
enum CalendarSearch {
    static let fillerWords: Set<String> = [
        "a", "an", "the", "my", "our", "your", "with", "at", "on", "in", "for", "to", "of", "and", "or", "about", "from",
        "event", "events", "calendar",
    ]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !fillerWords.contains($0) }
    }

    static func haystack(_ event: CalendarEventRecord) -> String {
        var parts = [event.title, event.location ?? "", event.notes ?? "", event.calendar?.title ?? ""]
        for attendee in event.attendees { parts.append(attendee.name ?? ""); parts.append(attendee.email ?? "") }
        return fold(parts.joined(separator: " "))
    }

    /// Events containing every query word; if none do, events containing any of them (`partial` true).
    static func filter(_ events: [CalendarEventRecord], query: String) -> (events: [CalendarEventRecord], partial: Bool) {
        let words = tokens(query)
        guard !words.isEmpty else { return (events, false) }
        let indexed = events.map { ($0, haystack($0)) }
        let all = indexed.filter { _, text in words.allSatisfy { text.contains($0) } }.map(\.0)
        if !all.isEmpty { return (all, false) }
        return (indexed.filter { _, text in words.contains { text.contains($0) } }.map(\.0), true)
    }
}

enum CalendarTools {
    static let maxSpan: TimeInterval = 366 * 24 * 3_600
    static let maxEventLength: TimeInterval = 14 * 24 * 3_600

    // MARK: Find

    static func findEvents(service: CalendarService) -> AppTool {
        AppTool.make(
            spec: ToolSpec(
                name: AppToolName.calendarFindEvents,
                description: """
                Look up events in the user's calendars (every account in the Mac's Calendar app). Use a named \
                range, or start and end dates; add query to match words in the title, place, notes or attendees. \
                With only a query, the next 30 days are searched; with nothing, today. Times come back in the \
                user's time zone with an offset, plus the weekday. Result status: ok with events, \
                permission_denied, unavailable, or invalid_request.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "range": ["type": "string", "enum": .array(CalendarRangeName.allCases.map { .string($0.rawValue) }),
                                  "description": "A named time range. Leave out when giving start or end."],
                        "start": ["type": "string", "description": "Start of the window: 2026-11-03 or 2026-11-03T09:00 (local time) or with an offset."],
                        "end": ["type": "string", "description": "End of the window. A plain date includes that whole day."],
                        "query": ["type": "string", "description": "Words to look for, e.g. \"dentist\" or \"Sam\"."],
                        "calendar": ["type": "string", "description": "Only events from calendars whose name contains this."],
                        "include_all_day": ["type": "boolean", "description": "Include all-day events (default true)."],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Most events to return (default 10)."],
                    ],
                    "additionalProperties": false,
                ]),
            needsFollowUpRound: true, defersUntilNarrationEnds: false, isReadOnly: true,
            statusLabel: "Checking your calendar…",
            parse: { try parseFind($0, clock: service.clock) },
            perform: { await find($0, service: service) })
    }

    static func parseDate(_ text: String, key: String, clock: CalendarClock) throws -> CalendarDateInput {
        guard let parsed = CalendarDateParser.parse(text, calendar: clock.calendar) else {
            throw ToolArgumentError("\"\(key)\" must be a date like 2026-11-03 or a time like 2026-11-03T14:00.")
        }
        return parsed
    }

    static func parseFind(_ arguments: ToolArguments, clock: CalendarClock) throws -> CalendarFindRequest {
        let now = clock.now()
        let calendar = clock.calendar
        let range = try arguments.choice("range", as: CalendarRangeName.self)
        let startText = try arguments.string("start", "from", maxLength: 64)
        let endText = try arguments.string("end", "to", maxLength: 64)
        let query = try arguments.string("query", "text", maxLength: 200)
        let calendarName = try arguments.string("calendar", "calendar_name", maxLength: 200)
        let includeAllDay = try arguments.bool("include_all_day") ?? true
        let limit = try arguments.int("limit", in: 1...50) ?? 10

        let interval: DateInterval
        let rangeName: String
        if startText != nil || endText != nil {
            guard range == nil else { throw ToolArgumentError("Give either range or start/end, not both.") }
            let start = try startText.map { try parseDate($0, key: "start", clock: clock) }
            let end = try endText.map { try parseDate($0, key: "end", clock: clock) }
            let startDate = start?.date ?? now
            let endDate: Date
            if let end {
                endDate = end.isDateOnly ? calendar.date(byAdding: .day, value: 1, to: end.date) ?? end.date : end.date
            } else if let start, start.isDateOnly {
                endDate = calendar.date(byAdding: .day, value: 1, to: start.date) ?? start.date
            } else {
                endDate = startDate.addingTimeInterval(24 * 3_600)
            }
            guard endDate > startDate else { throw ToolArgumentError("\"end\" must be after \"start\".") }
            interval = DateInterval(start: startDate, end: endDate)
            rangeName = "custom"
        } else if let range {
            interval = range.interval(now: now, calendar: calendar)
            rangeName = range.rawValue
        } else if query != nil {
            let startOfToday = calendar.startOfDay(for: now)
            interval = DateInterval(start: startOfToday, end: calendar.date(byAdding: .day, value: 30, to: startOfToday) ?? now)
            rangeName = "next_30_days"
        } else {
            interval = CalendarRangeName.today.interval(now: now, calendar: calendar)
            rangeName = CalendarRangeName.today.rawValue
        }
        guard interval.duration <= maxSpan else { throw ToolArgumentError("Search at most one year at a time.") }
        return CalendarFindRequest(interval: interval, rangeName: rangeName, query: query, calendarName: calendarName,
                                   includeAllDay: includeAllDay, limit: limit)
    }

    static func find(_ request: CalendarFindRequest, service: CalendarService) async -> AppToolResult {
        if let problem = await service.ensureAccess(toRead: true) { return problem }
        let fetched: [CalendarEventRecord]
        do {
            fetched = try await service.store.events(from: request.interval.start, to: request.interval.end)
        } catch CalendarStoreError.accessDenied {
            return CalendarService.accessProblem(await service.store.authorization())
        } catch {
            return AppToolResult(.failed, "Reading the calendar failed: \(error)")
        }

        var events = fetched.filter { !$0.isCancelled && (request.includeAllDay || !$0.isAllDay) }
        // Overlap, not containment: a meeting running across the window's start still counts.
        events = events.filter { $0.end > request.interval.start && $0.start < request.interval.end }
        if let name = request.calendarName {
            let folded = CalendarSearch.fold(name)
            events = events.filter { CalendarSearch.fold($0.calendar?.title ?? "").contains(folded) }
        }
        var partial = false
        if let query = request.query { (events, partial) = CalendarSearch.filter(events, query: query) }
        events.sort { ($0.start, $0.title) < ($1.start, $1.title) }

        let tz = service.timeZone
        let now = service.clock.now()
        let shown = events.prefix(request.limit)
        var details: [String: JSONValue] = [
            "range": [
                "name": .string(request.rangeName),
                "start": .string(CalendarTimeFormat.timestamp(request.interval.start, timeZone: tz)),
                "end": .string(CalendarTimeFormat.timestamp(request.interval.end, timeZone: tz)),
                "time_zone": .string(tz.identifier),
            ],
            "count": .number(Double(shown.count)),
            "total": .number(Double(events.count)),
            "truncated": .bool(events.count > shown.count),
            "events": .array(shown.map { service.json($0, now: now) }),
        ]
        if request.query != nil { details["match"] = .string(partial ? "partial" : "all_words") }
        let message: String? = events.isEmpty
            ? (request.query == nil ? "No events in that time range." : "No events matched in that time range.")
            : (partial ? "No event matched every word; these match some of them." : nil)
        return AppToolResult(.ok, message, details: details)
    }

    // MARK: Create

    static func createEvent(service: CalendarService) -> AppTool {
        AppTool.make(
            spec: ToolSpec(
                name: AppToolName.calendarCreateEvent,
                description: """
                Add an event to the user's calendar, in two steps. Call without confirmed to get a draft (status \
                needs_confirmation, nothing saved); read it back and ask. When the user agrees, call again with \
                confirmed true and the draft_id. If they change something, send the new details without draft_id \
                for a new draft. Set confirmed true on the first call only when the user's own \
                words already asked you to add this exact event. Result status: needs_confirmation, created, \
                permission_denied, unavailable, not_found (the draft expired), or invalid_request.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "What the event is called."],
                        "start": ["type": "string", "description": "2026-11-03T14:00 (local time) or 2026-11-03 for an all-day event."],
                        "end": ["type": "string", "description": "When it ends. For all-day events, the last day it covers."],
                        "duration_minutes": ["type": "integer", "minimum": 1, "description": "Length instead of end (default 60)."],
                        "all_day": ["type": "boolean", "description": "An all-day event (default: true when start has no time)."],
                        "location": ["type": "string"],
                        "notes": ["type": "string"],
                        "calendar": ["type": "string", "description": "Name of the calendar to use; default is the user's default calendar."],
                        "confirmed": ["type": "boolean", "description": "The user has approved this exact event."],
                        "draft_id": ["type": "string", "description": "The draft to save, from an earlier needs_confirmation result."],
                    ],
                    "additionalProperties": false,
                ]),
            needsFollowUpRound: true, defersUntilNarrationEnds: false, isReadOnly: false,
            statusLabel: "Adding it to your calendar…",
            parse: { try parseCreate($0, clock: service.clock) },
            perform: { await create($0, service: service) })
    }

    /// The argument keys that describe the event itself (everything but `draft_id` and `confirmed`).
    static let eventDetailKeys = ["title", "start", "end", "duration_minutes", "duration", "all_day", "location", "notes",
                                  "description", "calendar", "calendar_name"]

    static func parseCreate(_ arguments: ToolArguments, clock: CalendarClock) throws -> CalendarCreateRequest {
        let confirmed = try arguments.bool("confirmed") ?? false
        guard let id = try arguments.string("draft_id", maxLength: 64) else {
            return .new(try parseNewEvent(arguments, clock: clock), confirmed: confirmed)
        }
        guard eventDetailKeys.contains(where: arguments.has) else { return .existingDraft(id: id, confirmed: confirmed) }
        do {
            return .revisedDraft(id: id, try parseNewEvent(arguments, clock: clock), confirmed: confirmed)
        } catch let error as ToolArgumentError {
            throw ToolArgumentError("""
                \(error.message) To save draft \(id) as it is, send only draft_id and confirmed; to change it, send \
                every detail of the event.
                """, status: error.status)
        }
    }

    static func parseNewEvent(_ arguments: ToolArguments, clock: CalendarClock) throws -> CalendarNewEvent {
        let calendar = clock.calendar
        let now = clock.now()
        let title = try arguments.requiredString("title", maxLength: 200)
        let start = try parseDate(try arguments.requiredString("start", maxLength: 64), key: "start", clock: clock)
        let isAllDay = try arguments.bool("all_day") ?? start.isDateOnly
        let endText = try arguments.string("end", maxLength: 64)
        let duration = try arguments.int("duration_minutes", "duration", in: 1...Int(maxEventLength / 60))
        guard endText == nil || duration == nil else { throw ToolArgumentError("Give end or duration_minutes, not both.") }

        let startDate: Date
        let endDate: Date
        if isAllDay {
            startDate = calendar.startOfDay(for: start.date)
            if let endText {
                let end = try parseDate(endText, key: "end", clock: clock)
                let lastDay = calendar.startOfDay(for: end.date)
                endDate = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            } else {
                let days = max(1, Int((Double(duration ?? 1_440) / 1_440).rounded(.up)))
                endDate = calendar.date(byAdding: .day, value: days, to: startDate) ?? startDate
            }
        } else {
            guard !start.isDateOnly else { throw ToolArgumentError("\"start\" needs a time unless all_day is true.") }
            startDate = start.date
            if let endText {
                let end = try parseDate(endText, key: "end", clock: clock)
                guard !end.isDateOnly else { throw ToolArgumentError("\"end\" needs a time unless all_day is true.") }
                endDate = end.date
            } else {
                endDate = startDate.addingTimeInterval(TimeInterval(duration ?? 60) * 60)
            }
        }
        guard endDate > startDate else { throw ToolArgumentError("The event must end after it starts.") }
        guard endDate.timeIntervalSince(startDate) <= maxEventLength else { throw ToolArgumentError("Events can be at most 14 days long.") }
        guard startDate > now.addingTimeInterval(-maxSpan), startDate < now.addingTimeInterval(5 * maxSpan) else {
            throw ToolArgumentError("That date is too far from today. Check the year.")
        }

        return CalendarNewEvent(
            title: title, start: startDate, end: endDate, isAllDay: isAllDay,
            location: try arguments.string("location", maxLength: 500),
            notes: try arguments.string("notes", "description", maxLength: 4_000),
            calendarName: try arguments.string("calendar", "calendar_name", maxLength: 200))
    }

    static func create(_ request: CalendarCreateRequest, service: CalendarService) async -> AppToolResult {
        let now = service.clock.now()
        switch request {
        case .existingDraft(let id, let confirmed):
            return await confirmDraft(id, confirmed: confirmed, service: service, now: now)

        case .revisedDraft(let id, let event, let confirmed):
            if let problem = await service.ensureAccess(toRead: false) { return problem }
            let draft: CalendarEventDraft, note: String?
            switch await makeDraft(event, service: service) {
            case .success(let made): (draft, note) = made
            case .failure(let problem): return problem.result
            }
            // The same details as the draft: an echo of what the user approved.
            if await service.drafts.state(id, now: now).draft == draft {
                return await confirmDraft(id, confirmed: confirmed, service: service, now: now)
            }
            // Different details are not what the user approved: never save them; make a new draft to read back.
            await service.drafts.remove(id)
            let newID = await service.drafts.add(draft, now: now)
            var result = needsConfirmation(draft, id: newID, service: service)
            result.message = """
                Nothing was saved: these details differ from draft \(id), or it has expired. Read this new draft back \
                to the user. If they agree, call calendar_create_event with confirmed true and draft_id \(newID).
                """
            result.details["replaces_draft_id"] = .string(id)
            if let note { result.details["note"] = .string(note) }
            return result

        case .new(let event, let confirmed):
            if let problem = await service.ensureAccess(toRead: false) { return problem }
            let draft: CalendarEventDraft, note: String?
            switch await makeDraft(event, service: service) {
            case .success(let made): (draft, note) = made
            case .failure(let problem): return problem.result
            }
            guard confirmed else {
                let id = await service.drafts.add(draft, now: now)
                var result = needsConfirmation(draft, id: id, service: service)
                if let note { result.details["note"] = .string(note) }
                return result
            }
            var result = await save(draft, service: service)
            if let note { result.details["note"] = .string(note) }
            return result
        }
    }

    /// Reads a draft back, or saves it once when confirmed.
    static func confirmDraft(_ id: String, confirmed: Bool, service: CalendarService, now: Date) async -> AppToolResult {
        guard confirmed else {
            switch await service.drafts.state(id, now: now) {
            case .waiting(let draft): return needsConfirmation(draft, id: id, service: service)
            case .beingSaved, .saved: return alreadySaved(id, service: service)
            case .missing: return draftNotFound
            }
        }
        if let problem = await service.ensureAccess(toRead: false) { return problem }
        switch await service.drafts.claim(id, now: now) {
        case .waiting(let draft):
            let result = await save(draft, service: service)
            await service.drafts.finishSaving(id, saved: result.status == .created, now: service.clock.now())
            return result
        case .beingSaved:
            return AppToolResult(.invalidRequest, "Nothing more was saved: an earlier call is saving this draft now.",
                                 details: ["draft_id": .string(id)])
        case .saved:
            return alreadySaved(id, service: service)
        case .missing:
            return draftNotFound
        }
    }

    static let draftNotFound = AppToolResult(.notFound, "That draft has expired or does not exist. Make a new one from the event details.")

    static func alreadySaved(_ id: String, service: CalendarService) -> AppToolResult {
        AppToolResult(.created, "This draft was saved already, once; nothing more was added.",
                      details: ["draft_id": .string(id), "already_saved": true])
    }

    /// The draft for a parsed event: the calendar it names (or the default) and the zone right now.
    static func makeDraft(_ event: CalendarNewEvent, service: CalendarService) async
        -> Result<(CalendarEventDraft, String?), CalendarProblem> {
        switch await resolveCalendar(named: event.calendarName, service: service) {
        case .success(let (target, note)):
            let draft = CalendarEventDraft(title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                                           location: event.location, notes: event.notes, calendar: target,
                                           timeZone: service.fixedTimeZone)
            return .success((draft, note))
        case .failure(let problem):
            return .failure(problem)
        }
    }

    struct CalendarProblem: Error { var result: AppToolResult }

    /// The writable calendar the user named (exact name first, then a partial match). Nil target: the default.
    static func resolveCalendar(named name: String?, service: CalendarService) async
        -> Result<(CalendarInfo?, String?), CalendarProblem> {
        guard let name else { return .success((await service.store.defaultCalendar(), nil)) }
        guard await service.store.authorization().canRead else {
            return .success((await service.store.defaultCalendar(),
                             "OpenClicky can't see the calendar list with add-only access, so the default calendar is used."))
        }
        let writable = await service.store.calendars().filter(\.isWritable)
        let folded = CalendarSearch.fold(name)
        if let exact = writable.first(where: { CalendarSearch.fold($0.title) == folded }) { return .success((exact, nil)) }
        if let partial = writable.first(where: { CalendarSearch.fold($0.title).contains(folded) }) { return .success((partial, nil)) }
        let names = writable.prefix(15).map { JSONValue.string($0.title) }
        return .failure(CalendarProblem(result: AppToolResult(.invalidRequest, "There is no calendar called \"\(name)\" that takes new events.",
                                                              details: ["calendars": .array(Array(names))])))
    }

    static func needsConfirmation(_ draft: CalendarEventDraft, id: String, service: CalendarService) -> AppToolResult {
        AppToolResult(.needsConfirmation, """
            Nothing is saved yet. Read the event back to the user. If they agree, call calendar_create_event with \
            confirmed true and this draft_id.
            """, details: ["draft": service.json(draft), "draft_id": .string(id)])
    }

    static func save(_ draft: CalendarEventDraft, service: CalendarService) async -> AppToolResult {
        do {
            let saved = try await service.store.save(draft)
            return AppToolResult(.created, "The event is in the calendar.", details: ["event": service.json(saved, now: service.clock.now())])
        } catch CalendarStoreError.accessDenied {
            return CalendarService.accessProblem(await service.store.authorization())
        } catch {
            return AppToolResult(.failed, "\(error)")
        }
    }
}
