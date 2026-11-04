// Tiny static file server for the e2e test page (bound to 127.0.0.1).
const http = require("http"), fs = require("fs"), path = require("path");
const [root, port] = [process.argv[2], Number(process.argv[3])];
http.createServer((req, res) => {
  const file = path.join(root, path.normalize(decodeURIComponent(req.url.split("?")[0])).replace(/^\/+/, "") || "page.html");
  if (!file.startsWith(root)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end("not found"); }
    res.writeHead(200, { "Content-Type": file.endsWith(".html") ? "text/html; charset=utf-8" : "application/octet-stream" });
    res.end(data);
  });
}).listen(port, "127.0.0.1", () => console.log(`serving ${root} on http://127.0.0.1:${port}/`));
