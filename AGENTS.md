# NotesMate repository guidance

- Every new user-facing UI string must be translated in the same change into all 15 languages supported by `EditorLanguage.supported`. Add the key and translation to every `NotesMate/Localization/*.lproj/Localizable.strings` file, including accessibility text, menu items, alerts, and tips. Keep the localization completeness test passing.
- Before editing, deleting, or reverting an existing working-tree change that you did not introduce, ask the user for confirmation. This also applies to changes the user makes while a task is in progress; if authorship is unclear, preserve the change and ask first.
- For tip display time, prefer the short (1.5 s), medium (3 s), and long (5 s) presets. Choose the closest preset for new tips, with medium as the default, and avoid a separate absolute duration unless a specific requirement calls for it.
- After every build, report the artifact's containing folder as a clickable Markdown link (e.g. `[build/Build/Products/Debug](file:///…/build/Build/Products/Debug/)`) so the user can click to open the folder; do not link the artifact file itself, and never paste a bare absolute path alone.
