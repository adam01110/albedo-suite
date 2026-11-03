# FFF worker source and licenses

The suite's adapter is licensed under AGPL-3.0-only with the Classpath exception
and installed in readable, unminified source form at
`<package>/libexec/albedo-fff.mjs`. Its license and exception are in the adjacent
`LICENSE`. Keep that source and notice with copies of the adapter. The exception
permits linking independent modules under their own licenses, not exempting
changes to the adapter itself.

When conveying executable forms, supply the exact Corresponding Source and
required build materials using a method permitted by AGPL section 6. For a
modified program supporting remote network interaction, provide the prominent,
no-charge network source offer required by AGPL section 13. This source file and
local notice do not implement a remote source-serving endpoint or offer.

The FFF SDK/native indexer and ffi-rs are separate MIT-licensed dependencies.
Their license texts are retained as `fff-LICENSE` and `ffi-rs-LICENSE` here.
The installed npm packages retain their package metadata and any bundled notices
under `<package>/lib/node_modules/`. These components are not relicensed by the
suite's AGPL license or Classpath exception.
