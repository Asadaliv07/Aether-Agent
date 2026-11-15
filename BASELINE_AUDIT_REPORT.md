# AETHER — COMPLETE TOOL ECOSYSTEM & AGENT FUNCTIONALITY AUDIT
## Baseline Audit Report (Task One)

**Date:** November 7, 2026  
**Target Platform:** macOS 14.0+, Apple Silicon (`arm64`), Swift 6.0  
**Audit Target:** Entire Aether Tool Ecosystem, Registries, Dispatchers, and Execution Bridges  

---

### 1. Implemented Tools vs Registered Tools Inventory

| Category | Implemented Tools | Registered in ChatViewModel.initialize() | Status / Gap |
| :--- | :--- | :--- | :--- |
| **Native System & Utility** | 5 tools (`system_info`, `calculator`, `file_reader`, `extract_document_text`, `system_notification`) | 5 registered | **Functional** (missing date/time utility) |
| **Filesystem (MCP)** | 14 tools (`create_folder`, `list_directory`, `search_directories`, `rename_folder`, `create_file`, `read_file`, `write_file`, `append_file`, `copy_file`, `move_file`, `rename_file`, `delete_file`, `search_files`, `get_file_metadata`) | 14 registered via MCPClient | **Failing on startup** due to empty `authorizedRoots` collection in `AuthorizedDirectoryManager`; missing alias `get_file_info` |
| **Browser Automation** | 15 tools in `BrowserAutomationTools` (`browser_open`, `browser_get_page_content`, `browser_get_page_metadata`, `browser_find_element`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_scroll`, `browser_go_back`, `browser_go_forward`, `browser_refresh`, `browser_get_screenshot`, `browser_list_tabs`, `browser_close_tab`, `browser_wait_for_element`) | **0 registered** (Omitted from `ChatViewModel.initialize()`) | **Critical Gap**: Model cannot discover or call any browser tools; missing `open_url` tool |
| **Desktop Automation** | 13 tools in `DesktopAutomationTools` (`app_list_running`, `app_get_frontmost`, `app_launch`, `app_get_windows`, `app_get_accessibility_tree`, `app_find_element`, `app_click`, `app_type_text`, `app_press_key`, `app_scroll`, `app_get_element_value`, `app_set_element_value`, `app_capture_screenshot`) | **0 registered** (Omitted from `ChatViewModel.initialize()`) | **Critical Gap**: Model cannot discover or call any desktop automation tools |
| **Native Application Control** | 0 dedicated tools (only `app_launch` existed in desktop automation with a 6-app whitelist) | **0 registered** | **Critical Gap**: Missing `open_application`, `quit_application`, `activate_application`, `switch_application`, `open_file_with_default_application`, `open_folder_in_finder` |

---

### 2. Detailed Failure Analyses

#### Failure A: Filesystem Authorization Rejection
- **Error:** `Filesystem path validation failed for parameter 'path': Access to protected system path is forbidden: No directories have been authorized for agent access.`
- **Inspection Finding:**
  `AuthorizedDirectoryManager.init()` loads bookmarks from `UserDefaults`. On fresh installations, `authorizedRoots` is empty (`[]`).
  In `SettingsView.swift`, there is NO UI or setting to authorize directories.
  When any tool requiring a filesystem path is called, `AuthorizedDirectoryManager.validateAndResolve` encounters `guard !authorizedRoots.isEmpty` and immediately throws `protectedSystemPath("No directories have been authorized for agent access.")`.
  The user is given no UI to grant access, and the error does not guide the user to resolve it.

#### Failure B: Browser Navigation Unavailable (`open_url tool is not available`)
- **Inspection Finding:**
  1. `BrowserAutomationTools.allTools()` was never registered in `ChatViewModel.initialize()`.
  2. The tool in `BrowserAutomationTools` was named `browser_open`, but the LLM and user queries commonly generate `open_url` or `navigate_browser`.
  3. No alias mapping or dedicated `open_url` tool existed.
  4. WebKit browser engine was never connected to the active tool execution loop in `ChatViewModel`.

#### Failure C: Native macOS Applications Not Opening
- **Inspection Finding:**
  1. `DesktopAutomationTools.allTools()` was never registered in `ChatViewModel.initialize()`.
  2. `NativeDesktopAutomationProvider.permittedApplications` was hardcoded to a tiny whitelist of 6 apps (`Finder`, `Safari`, `TextEdit`, `Notes`, `System Settings`, `System Preferences`). Calculator, Calendar, Mail, Terminal, Preview, etc., were rejected with `applicationLaunchFailed`.
  3. For Finder, `activate()` was called, but if Finder had no open windows, activating it produced zero visible change.
  4. The tools `open_application`, `quit_application`, `activate_application`, `switch_application`, `open_file_with_default_application`, and `open_folder_in_finder` were completely missing.

#### Failure D: Incomplete Agent Functionality & Prompt De-synchronization
- **Inspection Finding:**
  1. Tool registration was fragmented across files rather than unified in `ToolRegistry`.
  2. The system prompt in `ProductionAgentInferenceProvider` listed tools in documentation text that were not actually registered in `ToolRegistry`, confusing the model.
  3. Errors from missing permissions (e.g. Accessibility or Screen Recording) lacked clear guidance.
  4. Security-scoped bookmarks lacked comprehensive lifecycle management (`startAccessingSecurityScopedResource` and `stopAccessingSecurityScopedResource` on resolved roots).

---

### 3. Action Plan for Full Restoration
1. Build `FilesystemPermissionView` and integrate it into `SettingsView.swift`.
2. Enhance `AuthorizedDirectoryManager` with directory details, common directory authorization (Desktop, Documents, Downloads), NSOpenPanel integration, and security-scoped bookmark lifecycle management.
3. Implement `NativeApplicationTools` providing `open_application`, `quit_application`, `activate_application`, `switch_application`, `open_file_with_default_application`, and `open_folder_in_finder`.
4. Expand `BrowserAutomationTools` with `open_url`, `navigate_browser`, `browser_back`, `browser_forward`, `browser_refresh`, `browser_get_current_url`, `browser_get_screenshot`, `browser_wait_for_page`.
5. Add `get_file_info` alias to `MCPFilesystemServer` / `MCPToolAdapter`.
6. Add `current_date_time` utility tool.
7. Implement unified registration in `ToolRegistry.registerAllDefaultTools(...)`.
8. Connect all tools in `ChatViewModel.initialize()`.
9. Synchronize model prompt and parsing in `ProductionAgentInferenceProvider.swift`.
10. Build automated test suites and execute real-model validation.

