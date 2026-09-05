import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync, writeFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const metadata = JSON.parse(execFileSync("cargo", [
  "metadata", "--manifest-path", resolve(root, "src-tauri/Cargo.toml"),
  "--locked", "--format-version", "1", "--filter-platform", "x86_64-pc-windows-msvc",
], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }));
const escape = value => String(value).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
const packages = metadata.packages.filter(p => p.source).sort((a, b) => a.name.localeCompare(b.name));
const sections = [];
for (const pkg of packages) {
  const directory = dirname(pkg.manifest_path);
  const files = readdirSync(directory).filter(name => /^(LICENSE|LICENCE|COPYING|NOTICE)([._-]|$)/i.test(name))
    .map(name => resolve(directory, name)).filter(path => statSync(path).isFile());
  if (pkg.license_file) files.push(resolve(directory, pkg.license_file));
  const texts = [...new Set(files)].filter(existsSync).map(file => readFileSync(file, "utf8"));
  sections.push("<section><h2>" + escape(pkg.name + " " + pkg.version) + "</h2><p>" + escape(pkg.license ?? "") + "</p>"
    + texts.map(text => "<pre>" + escape(text) + "</pre>").join("")
    + (texts.length ? "" : "<p>License expression declared in the package manifest; see the upstream project for its notices.</p>") + "</section>");
}
const apiRoot = resolve(root, "node_modules/@tauri-apps/api");
for (const name of readdirSync(apiRoot).filter(n => /^LICENSE/i.test(n))) {
  const path = resolve(apiRoot, name);
  if (statSync(path).isFile()) sections.push("<section><h2>@tauri-apps/api</h2><pre>" + escape(readFileSync(path, "utf8")) + "</pre></section>");
}
writeFileSync(resolve(root, "ThirdPartyLicenses.html"), "<!doctype html><html lang=en><meta charset=utf-8><title>TokenBar Windows third-party licenses</title>"
  + "<style>body{font:14px/1.6 sans-serif;max-width:900px;margin:32px auto}pre{white-space:pre-wrap}section{border-top:1px solid #ccc;margin-top:24px}</style>"
  + "<h1>TokenBar Windows third-party licenses</h1><p>Generated from the locked Windows Rust dependency graph and bundled Tauri JavaScript API.</p>"
  + sections.join("\n") + "</html>");
console.log("Generated Windows dependency notices for " + packages.length + " Rust packages.");
