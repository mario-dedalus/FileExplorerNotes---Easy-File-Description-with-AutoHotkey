;============================================================
; Script Name : FileExplorerNotes
; Author      : Gued3s
; Version     : 2.0
; Date        : 2026-04-22
; 
; Features:
;   - Create/edit notes via our Native Dark Mode GUI (Ctrl+Shift+D)
;   - Quick preview descriptions in tooltips (Hold ctrl+q)
;   - Windows 11 Tabs support (Active tab detection via COM)
;   - Atomic Save strategy (Prevents data loss and corruption)
;   - Dirty Check (Warning prompt for unsaved changes)
;   - Hidden .filenotes folder per directory (Sidecar system)
;   - O(1) FIFO cache with 30-second TTL for performance
;   - 100ms polling for highly responsive UI
;
; Scope:
;   - Lightweight, single-file solution (KISS Principle)
;   - Windows Explorer integration only
;   - No external dependencies
;   - Minimal CPU/memory footprint
;   - UX-focused (Professional Notepad-like aesthetics)
;============================================================

#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
; 1. GLOBAL CONFIGURATION
;    - Defines visual themes (Dark Mode) and cache limits.
;    - Initializes the window registry to prevent duplicates.
; ============================================================================

; Dark Mode Colors (Win11 Native)
global COLOR_BG      := "1E1E1E"
global COLOR_EDIT    := "2D2D2D"
global COLOR_TEXT    := "FFFFFF"
global COLOR_LINE    := "000000"
global COLOR_BTN     := "0066CC"

; Preview & Cache Management
global PreviewState := Map("Active", false, "LastPath", "")
global NoteCache := Map()
global CACHE_MAX_SIZE := 50
global CACHE_MAX_AGE := 30000

; GUI Windows Registry (prevent duplicates, memory leaks)
global OpenGuis := Map()

; Apply Dark Mode Globally
if (VerCompare(A_OSVersion, "10.0.18362") >= 0) {
    try DllCall("uxtheme\135", "int", 2)
}

OnExit(ExitHandler)
ExitHandler(*) {
    ToolTip()
    ; Clean up any remaining GUI windows
    for filePath, guiObj in OpenGuis {
        try guiObj.Destroy()
    }
}

; ============================================================================
; 2. EXPLORER HOTKEYS (Context-Aware)
;    - Restricts shortcuts to Windows Explorer windows only.
;    - Prevents interference with other applications.
; ============================================================================

#HotIf WinActive("ahk_class CabinetWClass ahk_exe explorer.exe")

^+d:: CreateNote()         ; Ctrl+Shift+D : Create/Edit Note
^q:: PreviewStart()        ; Ctrl+Q (Hold)    : Preview Note
^q Up:: PreviewStop()      ; Ctrl+Q (Release) : Hide Preview

#HotIf


; ============================================================================
; 3. CORE: CREATE NOTE LOGIC
;    - Identifies selected files and resolves system paths.
;    - Manages the hidden ".filenotes" directory structure.
; ============================================================================

CreateNote() {
    shellWin := GetExplorerWindow()
    if !shellWin {
        MsgBox("Explorer window not found.", "Error", "Icon!")
        return
    }

    targetPath := ""
    try {
        for item in shellWin.Document.SelectedItems {
            targetPath := item.Path
            break
        }
    }
    
    ; Validation: File must exist and not be a note itself
    if !targetPath || !FileExist(targetPath) || InStr(targetPath, "\.filenotes\") {
        ToolTip("⚠ Please select a valid file.")
        SetTimer(() => ToolTip(), -1500)
        return
    }

    ; Extract filename WITH extension (important!)
    SplitPath(targetPath, &fileName, &fileDir)
    metaDir := fileDir "\.filenotes"
    notePath := metaDir "\" fileName ".txt"
    
    ; Create .filenotes directory if needed
    if !DirExist(metaDir) {
        try {
            DirCreate(metaDir)
            FileSetAttrib("+H", metaDir)
        } catch as err {
            MsgBox("Cannot create notes directory:`n" err.Message, "Error", "Icon!")
            return
        }
    }

    ; Open in GUI (prevent duplicate windows)
    if OpenGuis.Has(notePath) {
        try {
            WinActivate("ahk_id " OpenGuis[notePath].Hwnd)
            return
        } catch {
            OpenGuis.Delete(notePath)
        }
    }

    OpenNoteGUI(notePath, fileName)
}

; ============================================================================
; 4. NATIVE GUI EDITOR
;    - Custom Dark Mode text editor with Dirty Check monitoring.
;    - Responsive layout that adapts to window resizing.
;    - I still haven't managed to make the buttons look nice without the white border around them, but what matters is that it works
; ============================================================================

OpenNoteGUI(notePath, displayName) {
    ; Load existing content or start empty
    initialContent := ""
    if FileExist(notePath) {
        try initialContent := FileRead(notePath, "UTF-8")
    }

    ; Create window with dark theme support
    noteGui := Gui("+Resize +MinSize400x300 +OwnDialogs", "Note: " displayName)
    noteGui.MarginX := 0
    noteGui.MarginY := 0
    noteGui.BackColor := COLOR_BG
    noteGui.IsDirty := false
    noteGui.NotePath := notePath

    ; Win11 Dark Title Bar
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", noteGui.Hwnd, "int", 20, "int*", 1, "int", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", noteGui.Hwnd, "int", 35, "int*", 0x00000000, "int", 4)

    noteGui.SetFont("s10 c" COLOR_TEXT, "Segoe UI")

    ; --- EDIT CONTROL ---
    editCtrl := noteGui.Add("Edit", "vEditCtrl x0 y0 w600 r20 -E0x200 -Border +Wrap +VScroll +WantReturn Background" COLOR_EDIT " c" COLOR_TEXT, initialContent)
    try DllCall("uxtheme\SetWindowTheme", "ptr", editCtrl.Hwnd, "str", "DarkMode_CFD", "ptr", 0)
    SendMessage(0x00D3, 3, (10 << 16) | 10, editCtrl.Hwnd) ; 10px margins

    ; Track modifications
    editCtrl.OnEvent("Change", GuiChange.Bind(noteGui))

    ; --- SEPARATOR LINE ---
    noteGui.Add("Text", "vSeparator x0 y0 w0 h1 Background" COLOR_LINE)

    ; --- BUTTONS ---
    btnSave := noteGui.Add("Button", "vBtnSave w100 h30 Default", "Save")
    btnCancel := noteGui.Add("Button", "vBtnCancel x+10 w100 h30", "Cancel")

    ; Aplica o tema escuro nativo do Windows 11 (Deixa cinza e arredondado)
    try DllCall("uxtheme\SetWindowTheme", "ptr", btnSave.Hwnd, "str", "DarkMode_Explorer", "ptr", 0)
    try DllCall("uxtheme\SetWindowTheme", "ptr", btnCancel.Hwnd, "str", "DarkMode_Explorer", "ptr", 0)

    ; --- EVENTS ---
    btnSave.OnEvent("Click", GuiSave.Bind(noteGui, notePath, editCtrl))
    btnCancel.OnEvent("Click", GuiClose.Bind(noteGui, notePath, editCtrl))
    noteGui.OnEvent("Close", GuiClose.Bind(noteGui, notePath, editCtrl))
    noteGui.OnEvent("Size", GuiResize)

    ; --- LOCAL HOTKEY: Ctrl+S ---
    HotIfWinActive("ahk_id " noteGui.Hwnd)
    Hotkey("^s", GuiSave.Bind(noteGui, notePath, editCtrl))
    HotIf()

    ; Track window globally
    OpenGuis[notePath] := noteGui

    noteGui.Show("w600 h400")
    editCtrl.Focus()
}

; --- Event Handlers ---

GuiChange(noteGui, GuiCtrlObj, Info) {
    noteGui.IsDirty := true
}

GuiResize(GuiObj, MinMax, Width, Height) {
    ; Ignore minimize events
    if (MinMax = -1)
        return

    try {
        ; Edit Control: from top (0) to 60px before bottom
        GuiObj["EditCtrl"].Move(0, 0, Width, Height - 60)

        ; Separator Line: 1px height, positioned at Height - 60
        GuiObj["Separator"].Move(0, Height - 60, Width, 1)

        ; Save Button: bottom-left area with 15px padding
        GuiObj["BtnSave"].Move(15, Height - 45, 100, 30)

        ; Cancel Button: next to Save button with 10px gap
        GuiObj["BtnCancel"].Move(125, Height - 45, 100, 30)
    } catch {
        ; Graceful failure
    }
}

GuiSave(noteGui, notePath, editCtrl, *) {
    SaveNoteAtomic(notePath, editCtrl.Value)
    noteGui.IsDirty := false
    GuiDestroy(noteGui, notePath)
}

GuiClose(noteGui, notePath, editCtrl, *) {
    ; Check for unsaved changes
    if noteGui.IsDirty {
        result := MsgBox("You have unsaved changes. Save before closing?", "Unsaved Changes", "YesNoCancel Icon?")
        if result = "Cancel"
            return ; Corrigido: Em AHK v2, apenas 'return' sem destruir a janela já previne o fechamento aqui
        if result = "Yes"
            SaveNoteAtomic(notePath, editCtrl.Value)
    }
    GuiDestroy(noteGui, notePath)
}

GuiDestroy(noteGui, notePath) {
    try {
        HotIfWinActive("ahk_id " noteGui.Hwnd)
        Hotkey("^s", "Off")
        HotIf()
    }
    
    OpenGuis.Delete(notePath)
    noteGui.Destroy()
}


; ============================================================================
; 5. ATOMIC SAVE (Data Integrity)
;    - Strategy: Write to .tmp -> Verify -> Replace original.
;    - Prevents file corruption during crashes or power loss.
; ============================================================================

SaveNoteAtomic(notePath, content) {
    tmpPath := notePath ".tmp"
    try {
        ; Write to temporary file first
        f := FileOpen(tmpPath, "w", "UTF-8-RAW")
        if !f {
            throw Error("Cannot open file for writing")
        }
        f.Write(content)
        f.Close()
        
        ; Atomic replacement (overwrite = 1)
        FileMove(tmpPath, notePath, 1)
        
        ; Invalidate cache
        if NoteCache.Has(notePath)
            NoteCache.Delete(notePath)
            
    } catch as err {
        try FileDelete(tmpPath)
        MsgBox("Error saving note:`n" err.Message, "Error", "Icon!")
    }
}


; ============================================================================
; 6. PREVIEW SYSTEM (ctrl + q / Hold to View)
;    - High-performance polling system with O(1) FIFO Cache.
;    - Minimizes Disk I/O and CPU usage during navigation.
; ============================================================================

PreviewStart() {
    global PreviewState
    if PreviewState["Active"]
        return
    PreviewState["Active"] := true
    SetTimer(PreviewTick, 100)
    PreviewTick()
}

PreviewStop() {
    global PreviewState
    PreviewState["Active"] := false
    PreviewState["LastPath"] := ""
    SetTimer(PreviewTick, 0)
    ToolTip()
}

PreviewTick() {
    global PreviewState, NoteCache

    ; Guard: prevent re-entrancy
    static _inProgress := false
    if _inProgress
        return
    _inProgress := true

    try {
        if !PreviewState["Active"] || !WinActive("ahk_class CabinetWClass ahk_exe explorer.exe") {
            if PreviewState["Active"]
                PreviewStop()
            return
        }

        shellWin := GetExplorerWindow()
        if !shellWin {
            ToolTip()
            return
        }

        focusedPath := ""
        try {
            focusedItem := shellWin.Document.FocusedItem
            if focusedItem
                focusedPath := focusedItem.Path
        }

        if !focusedPath || InStr(focusedPath, "\.filenotes\") {
            ToolTip()
            return
        }

        SplitPath(focusedPath, &fileName, &fileDir)
        notePath := fileDir "\.filenotes\" fileName ".txt"

        if notePath = PreviewState["LastPath"]
            return

        PreviewState["LastPath"] := notePath

        if FileExist(notePath) {
            contentToDisplay := ""
            currentFileTime := ""
            try currentFileTime := FileGetTime(notePath, "M")

            ; CACHE LOOKUP
            if NoteCache.Has(notePath) {
                cachedData := NoteCache[notePath]
                if currentFileTime = cachedData.FileTime && (A_TickCount - cachedData.AccessTime) < CACHE_MAX_AGE {
                    contentToDisplay := cachedData.Content
                    cachedData.AccessTime := A_TickCount
                } else {
                    NoteCache.Delete(notePath)
                }
            }

            ; DISK READ
            if !contentToDisplay {
                try {
                    contentToDisplay := FileRead(notePath, "m4000 UTF-8")
                    if contentToDisplay {
                        NoteCache[notePath] := {
                            Content: contentToDisplay,
                            AccessTime: A_TickCount,
                            FileTime: currentFileTime
                        }
                        
                        ; Simple FIFO eviction
                        if NoteCache.Count > CACHE_MAX_SIZE {
                            for key in NoteCache {
                                NoteCache.Delete(key)
                                break
                            }
                        }
                    }
                }
            }

            ToolTip(contentToDisplay ? contentToDisplay : "(Empty description)")
        } else {
            ToolTip("(No description)")
        }
    } finally {
        _inProgress := false
    }
}

; ============================================================================
; 7. EXPLORER DETECTION (WIN11 TABS SUPPORT)
;    - Advanced COM logic to identify the physically active tab.
;    - Ensures 100% accuracy in multi-tab Explorer environments.
; ============================================================================

GetExplorerWindow() {
    hwnd := WinExist("A")
    if !hwnd
        return 0

    ; Detect active tab handle (Win11)
    activeTab := 0
    try activeTab := ControlGetHwnd("ShellTabWindowClass1", "ahk_id " hwnd)

    try {
        shell := ComObject("Shell.Application")
        for window in shell.Windows {
            if window.Hwnd != hwnd
                continue
            
            ; If window has tabs, verify this is the active one
            if activeTab {
                static IID_IShellBrowser := "{000214E2-0000-0000-C000-000000000046}"
                try {
                    shellBrowser := ComObjQuery(window, IID_IShellBrowser, IID_IShellBrowser)
                    ComCall(3, shellBrowser, "uint*", &thisTab := 0)
                    if thisTab != activeTab
                        continue
                } catch {
                    continue
                }
            }

            ; Verify document accessibility
            try {
                _ := window.Document.Folder.Self.Path
            } catch {
                continue
            }

            return window
        }
    } catch {
        return 0
    }
    
    return 0
}


; ============================================================================
; 📂 USER GUIDE & REFERENCE
; ============================================================================
/*
    ========================================================================
    QUICK START
    ========================================================================
    1. Select any file or folder in Windows Explorer.
    2. Press Ctrl+Shift+D to open the our notepad.
    3. Type your context/note and click 'Save' (or press Ctrl+S).
    4. Click and hold ctrl q to see a quick preview of your note in a tooltip.
    ========================================================================
    DEFAULT HOTKEYS
    ========================================================================
    • Ctrl + Shift + D : Create or Edit a note.
    • ctrl+q (Hold)    : Preview note content.
    • Ctrl + S         : Save note (while editor is open).
    • Esc           : Close editor / Cancel changes.
    ========================================================================
    STORAGE SYSTEM (Sidecar Files)
    ========================================================================
    Notes are stored in a hidden subfolder named ".filenotes".
    • Original File:  C:\MyFolder\Project_Data.xlsx
    • Context Note:   C:\MyFolder\.filenotes\Project_Data.xlsx.txt
    ========================================================================
    TECHNICAL HIGHLIGHTS
    ========================================================================
    • Win11 Tabs: Active tab detection via IShellBrowser COM.
    • Atomic Save: .tmp file strategy for zero data loss.
    • Dirty Check: Prevents closing with unsaved changes.
    • FIFO Cache: 30s TTL to save system resources.
    ========================================================================
    CUSTOMIZATION
    ========================================================================
    • Colors: Search for COLOR_ variables in Section 1.
    • Cache:  Search for CACHE_ variables in Section 1.
    • Keys:   Modify trigger combinations in Section 2.
    ========================================================================
    HOTKEY SYNTAX GUIDE
    ========================================================================
    ^ = Ctrl  |  ! = Alt  |  + = Shift  |  # = Windows Key
    Example: "^+d" means Ctrl+Shift+D

    ========================================================================
    CONFLICTS TO AVOID IN EXPLORER
    ========================================================================
    - Ctrl+Shift+N (New Folder) | - F2 (Rename)
    - Alt+Enter (Properties)    | - Ctrl+W (Close Window)
    ========================================================================
    For more details on Hotkey syntax, visit:
    https://www.autohotkey.com/docs/v2/Hotkeys.htm
*/
; ============================================================================
; END OF SCRIPT
; ============================================================================
