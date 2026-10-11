import albedo/harness/extension

pub fn extension() -> extension.Extension {
  extension.python_module(
    "files",
    "Read, search, and exactly edit workspace files from Python.",
    "files",
    "files.read(path, start_line=, end_line=, limit=) returns complete numbered lines; limit counts lines, and a separate max_chars= budget (default 16000 characters) stops very large windows and says where to resume, files.ls(path, pattern=) lists one directory, files.write(path, content) creates or replaces a whole file, and files.edit(path, old, new) replaces one exact unique string, reporting every occurrence with line ranges when it is not unique; retry it with line_hint=<line>. These return immediately, and awaiting them also works. await files.find(pattern, path_or_paths, glob=, context=N, literal=, case_sensitive=, max_results=50, hidden=, ignored=) searches contents (a regex unless literal=True) with N surrounding lines. Search uses the mandatory FFF indexed engine; a missing root or dependency raises, and unsupported flags or regular expressions fail explicitly rather than falling back. Ignored files cannot be included. await files.paths(pattern) ranks fuzzy filename matches; wildcard patterns and glob= retain exact glob filtering. Results remain bounded by max_results; use a focused query instead of enumerating all paths. Search calls must be awaited. Prefer these over rg, grep, find, ls, cat, and sed through run().",
    ["python", "run"],
  )
}
