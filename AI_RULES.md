# AI Agent Rules — DispatchPH

## CRITICAL RULES (Never break these)

### 1. Never change app scope or architecture without approval
- Do NOT change the core purpose, features, or architecture of the app without explicit user approval first
- If a bug fix requires changing existing behavior, data structures, flows, or UI patterns — ASK FIRST before proceeding
- Present the change and its impact clearly, then wait for approval

### 2. Auto-release timer is 24 hours
- Debug mode: 30 seconds (for quick testing only)
- Production mode: 24 hours
- These values are by design — do NOT change them
- The app scope requires 24-hour auto-release to protect vendors from ghosting buyers

### 3. Bug fixes only — do not add features or refactor without asking
- When fixing a bug, fix ONLY the bug
- Do not refactor code, change naming, restructure files, or improve things that aren't broken
- Do not add new features or functionality unless explicitly asked
- If a fix reveals a deeper issue that needs architectural change, report it and wait for approval

### 4. Confirm before proceeding
- If you are unsure whether a change is within scope, ASK
- If a fix will affect multiple files or change behavior, ASK
- If you want to improve something you noticed, ASK
- The user decides what gets changed, not the AI

### 5. Preserve all existing functionality
- Never remove or break existing features
- Never change database schemas, RLS policies, or data models without approval
- Never change API contracts, endpoints, or data formats
- Always verify that existing features still work after a fix

### 6. Be transparent
- Tell the user exactly what you changed and why
- If you made a mistake, acknowledge it immediately and revert
- Do not make hidden changes or "improvements" the user didn't ask for

### 7. User-specified rules are permanent
- When the user specifies a rule (prefaced with "this is a rule"), save it to this file immediately
- Rules are permanent — never go against them no matter what
- Any change that affects app settings requires user approval
- If a change is needed that conflicts with or modifies a saved rule, explain WHY to the user and wait for explicit approval before proceeding

### 8. Never expose keys or secrets
- Never print, log, paste, or write any API key, service role key, secret key, access token, or credential into chat output, source files, shell commands, or any file the AI creates
- Never run a shell/CLI command with a secret embedded directly in the command string (it lands in shell history and process listings) — if a command needs a secret, tell the user to run it themselves or supply it through an env var/secret manager, not as a literal argument
- If a task requires a secret value (e.g. a service role key) to proceed, tell the user where to obtain it and where to paste it themselves — never ask the user to paste the secret into chat

### 9. Auto rebuild + install after device-relevant changes
- Whenever a code change is made that requires a rebuild to actually take effect on the test device (Dart/Flutter code changes, asset changes, etc.), proactively rebuild the app after confirming the device is connected (`adb devices`) — do not wait for the user to ask
- Use the same build command already established for this project: `flutter build apk --debug --target-platform android-arm64`, then `adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk`
- If the device is not connected/listed in `adb devices`, tell the user instead of skipping silently
- This does not apply to server-side-only changes (SQL, Edge Functions) that don't touch the Flutter app code — only rebuild when the change actually affects the installed APK
