# Comment Style Guide

For `.nix` files only. Not for prose docs, copied upstream option descriptions, or commit messages.

## Rules

- Keep comments short, local, ASCII, and indented to the code they describe.
- Write explanatory comments as sentence fragments in present tense, start with `#`, and end with `.`.
- Bare heading labels inside grouped lists may omit the period.
- Prefer standalone comments above code, not trailing comments.
- Comment intent, rationale, constraints, non-obvious transformations, generated structure, or meaningful grouping.
- Skip comments for self-explanatory assignments, simple `inherit` blocks unless a subgroup needs a label, obvious enable flags, boilerplate module structure, and syntax boundaries like `let`, `in`, `{}`, `with`, or lambda heads.

## Placement

- Put comments directly above the smallest useful binding, attrset, list, or expression.
- Group comments directly above the grouped block.
- Comments inside lists or attrsets are fine when labeling a subsection.
- Do not put comments after `{ ... }:` or `_:` before `let`, or anywhere between a module or lambda head and `let`.
- Do not use comments as spacers above `let`.
- If a whole-block comment would otherwise go there, put it as the first meaningful line inside `in {`.

## Allowed Exceptions

- Preserve `keep-sorted` and similar tool-control comments.
- Rare TODOs may use `# TODO(<owner or reason>): ...`.
- Existing emphatic or humorous comments are fine if they still help readability.
- Upstream-style package headings or labels are fine when preserving imported structure helps.

## Let Binding Order

For top-level and module `let ... in` expressions, use this order:

1. One contiguous library/helper import group: `builtins`, direct `lib`,
   upstream `lib.<namespace>` sources in a sensible order, `lib.self`, then
   helper APIs exposed through `pkgs`. Do not separate source groups with blank
   lines.
2. Actual package derivations inherited or aliased from package sets.
3. Format constructors such as `jsonFormat` and `tomlFormat`.
4. External configuration or imported values such as `vars` and `config`.
5. Configuration aliases such as `cfg`, `colors`, `secrets`, and `templates`.
6. Primitive constants and paths.
7. Package or executable aliases not already inherited.
8. Simple derived values.
9. Helper, constructor, and transformation functions.
10. Large generated scripts, lists, and attribute sets.

Use one blank line between semantic groups, not between every binding, and never
immediately after `let`. In particular, separate format constructors from the
preceding library/helper or package group with a blank line. Classify bindings by
purpose rather than source path. Package-building and platform APIs are helpers;
this includes `runCommand`, `writeShellApplication`, `writeText`,
`makeDesktopItem`, `mkShell`, `symlinkJoin`, `nixosOptionsDoc`, `buildVimPlugin`,
`toPythonApplication`, and similar APIs. Runtime/installable derivations such as `jq`, `json5`, `onefetch`,
fonts, plugins, and NUR packages are packages. Split mixed `inherit (pkgs)`
statements at the helper/package boundary. Keep nested and small lets dependency-
or concept-ordered unless these groups clearly apply.

## Keep-Sorted Patterns

- Use matching `keep-sorted` start/end control comments for multi-item module argument sets, `inherit` groups, lists, and compact attrsets.
- Add the `block=yes newline_separated=yes` flags for attrsets or lists whose entries are separated by blank lines.
- Put control comments inside the list or attrset they sort, indented to the entries.
- Do not add `keep-sorted` around single-item groups or every local `let` binding unless the surrounding file already does.
- Keep sorted dependency groups alphabetical, such as `after`, `requires`, `wantedBy`, and `wants`.

## Review Standard

- Delete comments that only restate code.
- Move misplaced file or block comments below `in {` in `let`-using files.
- Keep comments attached to the exact code they explain.
- Preserve required control comments.
- Prefer deleting a weak comment over keeping noise.
