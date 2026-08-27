<#
.TORUN
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\compiling_files.ps1
#>

<#
.SYNOPSIS
    Compiles multiple text files into one output file, or extracts files
    from previously compiled content.

.DESCRIPTION
    On start, the user chooses between Export and Import.
    - Export: Prompts for a folder, recursively lists readable files
      (including subdirectories) with numbers, optionally respects
      .gitignore rules, optionally skips the .git folder, allows selection
      via numbers/ranges or interactive UI, then compiles selected files 
      into one output with filename headers. Export options: Clipboard, File, or Both.
    - Import: Pops up a multiline textbox where the user can paste content
      in the same format produced by Export (Plain Text or Markdown). Files 
      are recreated at the specified destination folder. Existing files prompt 
      for replace confirmation via a visual diff window (Approve / Approve All / Cancel);
      missing directories are created automatically.

    Additional features:
    - Recent folders history (quick-select recently used folders)
    - Native Folder Browser Dialog
    - Tree-style file listing & Interactive Arrow-Key Selection with Expand/Collapse
    - Markdown/AI-Ready Export & Import
    - Diff summary before import & Line Numbers in Diff Viewer
    - Backup (.bak) before replace
    - Progress bar & Faster File Scanning for large file sets
    - Clipboard Size Warning
#>

# Force UTF-8 for all console I/O so characters survive
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
    $null = chcp 65001 > $null
} catch {
    # Non-interactive hosts may not allow setting these; ignore.
}

# ============================================
# WIN32 API FOR SYNCHRONIZED SCROLLING
# ============================================
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Win32Scroll {
    [DllImport("user32.dll")]
    public static extern int SendMessage(IntPtr hWnd, int wMsg, int wParam, int lParam);

    public const int EM_GETFIRSTVISIBLELINE = 0x00CE;
    public const int EM_LINESCROLL = 0x00B6;
}
"@ -ErrorAction SilentlyContinue

# ============================================
# C# DIFF ENGINE & RTF GENERATION (with Line Numbers & Correct Colors)
# ============================================
Add-Type @"
using System;
using System.Collections.Generic;
using System.Text;

public class DiffResult {
    public string OriginalRtf;
    public string NewRtf;
}

public class DiffEntry {
    public string Type { get; set; }
    public string Left { get; set; }
    public string Right { get; set; }
}

public class DiffGenerator {
    public static DiffResult Generate(string originalContent, string newContent) {
        string[] orig = SplitLines(originalContent);
        string[] nw = SplitLines(newContent);
        int m = orig.Length;
        int n = nw.Length;

        StringBuilder leftRtf = new StringBuilder();
        StringBuilder rightRtf = new StringBuilder();

        // RTF Header: Color table (0=Auto, 1=Black text, 2=LightRed, 3=LightGreen, 4=LightYellow), Font Consolas
        string header = @"{\rtf1\ansi\ansicpg1252\deff0\nouicompat\deflang1033{\fonttbl{\f0\fnil\fcharset0 Consolas;}}{\colortbl ;\red0\green0\blue0;\red255\green204\blue204;\red204\green255\blue204;\red255\green255\blue204;}\viewkind4\uc1\pard\f0\fs20\cf1 ";
        leftRtf.Append(header);
        rightRtf.Append(header);

        List<DiffEntry> diffs;
        if (m > 1500 || n > 1500) {
            // Fallback for massive files: Skip LCS to avoid OutOfMemoryException
            diffs = new List<DiffEntry>();
            int maxLen = Math.Max(m, n);
            for (int i = 0; i < maxLen; i++) {
                string l = i < m ? orig[i] : null;
                string r = i < n ? nw[i] : null;
                diffs.Add(new DiffEntry { Type = "Modified", Left = l, Right = r });
            }
        } else {
            diffs = ComputeLcsDiff(orig, nw);
        }

        string zws = "\u200B";
        int leftNum = 1;
        int rightNum = 1;

        foreach (var diff in diffs) {
            string l = diff.Left != null ? diff.Left : "";
            string r = diff.Right != null ? diff.Right : "";

            if (diff.Type == "Common") {
                AppendRtfLine(leftRtf, leftNum.ToString("D4") + "| " + l, 0); leftNum++;
                AppendRtfLine(rightRtf, rightNum.ToString("D4") + "| " + r, 0); rightNum++;
            } else if (diff.Type == "Deleted") {
                AppendRtfLine(leftRtf, leftNum.ToString("D4") + "| " + l, 2); leftNum++;
                AppendRtfLine(rightRtf, "    | " + zws, 2); // alignment, no num increment
            } else if (diff.Type == "Added") {
                AppendRtfLine(leftRtf, "    | " + zws, 3); // alignment, no num increment
                AppendRtfLine(rightRtf, rightNum.ToString("D4") + "| " + r, 3); rightNum++;
            } else if (diff.Type == "Modified") {
                bool hasLeft  = diff.Left != null;
                bool hasRight = diff.Right != null;
                if (hasLeft && hasRight) {
                    // True modification — both sides have content
                    AppendRtfLine(leftRtf, leftNum.ToString("D4") + "| " + l, 4); leftNum++;
                    AppendRtfLine(rightRtf, rightNum.ToString("D4") + "| " + r, 4); rightNum++;
                } else if (hasLeft) {
                    // Right side is null (extra deletes) — alignment on right, no number
                    AppendRtfLine(leftRtf, leftNum.ToString("D4") + "| " + l, 4); leftNum++;
                    AppendRtfLine(rightRtf, "    | " + zws, 4);
                } else if (hasRight) {
                    // Left side is null (extra adds) — alignment on left, no number
                    AppendRtfLine(leftRtf, "    | " + zws, 4);
                    AppendRtfLine(rightRtf, rightNum.ToString("D4") + "| " + r, 4); rightNum++;
                }
            }
        }

        leftRtf.Append("}");
        rightRtf.Append("}");

        return new DiffResult { OriginalRtf = leftRtf.ToString(), NewRtf = rightRtf.ToString() };
    }

    private static void AppendRtfLine(StringBuilder sb, string text, int colorIndex) {
        if (text == null) text = "";
        sb.Append("\\highlight" + colorIndex + " ");
        foreach (char c in text) {
            if (c == '\\') sb.Append("\\\\");
            else if (c == '{') sb.Append("\\{");
            else if (c == '}') sb.Append("\\}");
            else if (c == '\u200B') sb.Append("\\u8203?");
            else if (c > 127) sb.Append("\\u" + (int)c + "?");
            else sb.Append(c);
        }
        sb.Append("\\par\r\n");
    }

    private static string[] SplitLines(string content) {
        if (string.IsNullOrEmpty(content)) return new string[0];
        content = content.Replace("\r\n", "\n").Replace("\r", "\n");
        return content.Split('\n');
    }

    private static List<DiffEntry> ComputeLcsDiff(string[] a, string[] b) {
        int m = a.Length;
        int n = b.Length;
        int[,] dp = new int[m + 1, n + 1];

        // Build LCS matrix
        for (int i = 1; i <= m; i++) {
            for (int j = 1; j <= n; j++) {
                if (a[i - 1] == b[j - 1])
                    dp[i, j] = dp[i - 1, j - 1] + 1;
                else
                    dp[i, j] = Math.Max(dp[i - 1, j], dp[i, j - 1]);
            }
        }

        // Backtrack to find diff entries
        Stack<DiffEntry> stack = new Stack<DiffEntry>();
        int x = m, y = n;
        while (x > 0 || y > 0) {
            if (x > 0 && y > 0 && a[x - 1] == b[y - 1]) {
                stack.Push(new DiffEntry { Type = "Common", Left = a[x - 1], Right = b[y - 1] });
                x--; y--;
            } else if (y > 0 && (x == 0 || dp[x, y - 1] >= dp[x - 1, y])) {
                stack.Push(new DiffEntry { Type = "Added", Left = null, Right = b[y - 1] });
                y--;
            } else if (x > 0 && (y == 0 || dp[x - 1, y] > dp[x, y - 1])) {
                stack.Push(new DiffEntry { Type = "Deleted", Left = a[x - 1], Right = null });
                x--;
            }
        }

        // Post-process to group consecutive Deletes/Adds into Modified entries
        List<DiffEntry> result = new List<DiffEntry>();
        var arr = stack.ToArray();
        int k = 0;
        while (k < arr.Length) {
            if (arr[k].Type == "Deleted") {
                var delLines = new List<string>();
                delLines.Add(arr[k].Left);
                k++;
                while (k < arr.Length && arr[k].Type == "Deleted") {
                    delLines.Add(arr[k].Left);
                    k++;
                }
                if (k < arr.Length && arr[k].Type == "Added") {
                    var addLines = new List<string>();
                    addLines.Add(arr[k].Right);
                    k++;
                    while (k < arr.Length && arr[k].Type == "Added") {
                        addLines.Add(arr[k].Right);
                        k++;
                    }
                    int maxLen = Math.Max(delLines.Count, addLines.Count);
                    for (int d = 0; d < maxLen; d++) {
                        string l = d < delLines.Count ? delLines[d] : null;
                        string r = d < addLines.Count ? addLines[d] : null;
                        result.Add(new DiffEntry { Type = "Modified", Left = l, Right = r });
                    }
                } else {
                    foreach (var l in delLines)
                        result.Add(new DiffEntry { Type = "Deleted", Left = l, Right = null });
                }
            } else {
                result.Add(arr[k]);
                k++;
            }
        }
        return result;
    }
}
"@ -ErrorAction SilentlyContinue

# ============================================
# FUNCTION: Read-YesNoPrompt (default Y)
# ============================================
function Read-YesNoPrompt {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $hint = if ($DefaultYes) { "(Y/n)" } else { "(y/N)" }

    do {
        $response = Read-Host "$Prompt $hint"
        
        if ([string]::IsNullOrWhiteSpace($response)) {
            return $DefaultYes
        }
        if ($response -match '^[Yy]') { return $true }
        if ($response -match '^[Nn]') { return $false }
        
        Write-Warning "Please enter Y or N."
    } while ($true)
}

# ============================================
# FUNCTION: Parse selection string into indices
# ============================================
function Get-SelectedIndices {
    param(
        [string]$SelectionString,
        [int]$MaxIndex
    )

    $selectedIndices = [System.Collections.Generic.HashSet[int]]::new()
    $tokens = $SelectionString -split '\s+' | Where-Object { $_ -ne '' }

    foreach ($token in $tokens) {
        if ($token -match '^(\d+)-(\d+)$') {
            $start = [int]$matches[1]
            $end = [int]$matches[2]

            if ($start -gt $end) {
                Write-Warning "Invalid range '$token' (start > end). Skipping."
                continue
            }

            for ($i = $start; $i -le $end; $i++) {
                if ($i -ge 1 -and $i -le $MaxIndex) {
                    [void]$selectedIndices.Add($i)
                } else {
                    Write-Warning "Number $i in range '$token' is out of bounds. Skipping."
                }
            }
        }
        elseif ($token -match '^\d+$') {
            $num = [int]$token
            if ($num -ge 1 -and $num -le $MaxIndex) {
                [void]$selectedIndices.Add($num)
            } else {
                Write-Warning "Number $num is out of bounds (1-$MaxIndex). Skipping."
            }
        }
        else {
            Write-Warning "Invalid token '$token'. Skipping."
        }
    }

    return $selectedIndices | Sort-Object
}

# ============================================
# FUNCTION: Test if a file is likely readable text
# ============================================
function Test-IsReadableFile {
    param(
        [string]$FilePath
    )

    try {
        $buffer = New-Object byte[] 8192
        $fs = [System.IO.File]::OpenRead($FilePath)
        
        try {
            $bytesRead = $fs.Read($buffer, 0, 8192)
            for ($i = 0; $i -lt $bytesRead; $i++) {
                if ($buffer[$i] -eq 0) {
                    return $false
                }
            }
            return $true
        }
        finally {
            if ($null -ne $fs) {
                $fs.Dispose()
            }
        }
    }
    catch {
        return $false
    }
}

# ============================================
# FUNCTION: Convert a single .gitignore pattern to a regex
# ============================================
function Convert-GitignorePatternToRegex {
    param(
        [string]$Pattern
    )

    $anchored = $Pattern.StartsWith('/')
    if ($anchored) {
        $Pattern = $Pattern.Substring(1)
    }

    $dirOnly = $Pattern.EndsWith('/')
    if ($dirOnly) {
        $Pattern = $Pattern.TrimEnd('/')
    }

    $regex = [regex]::Escape($Pattern)

    $regex = $regex.Replace('\*\*', '§DOUBLESTAR§')
    $regex = $regex.Replace('\*', '[^/]*')
    $regex = $regex.Replace('§DOUBLESTAR§', '.*')
    $regex = $regex.Replace('\?', '[^/]')

    if ($anchored) {
        $regex = '^' + $regex
    }
    else {
        $regex = '(^|.*/)' + $regex
    }

    $regex = $regex + '(/.*)?$'

    return $regex
}

# ============================================
# FUNCTION: Load .gitignore patterns from a file
# ============================================
function Get-GitignorePatterns {
    param(
        [string]$GitignorePath
    )

    $patterns = [System.Collections.ArrayList]::new()
    $lines = [System.IO.File]::ReadAllLines($GitignorePath, [System.Text.UTF8Encoding]::new($false))

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $negate = $false
        if ($trimmed.StartsWith('!')) {
            $negate = $true
            $trimmed = $trimmed.Substring(1)
        }

        $regexPattern = Convert-GitignorePatternToRegex -Pattern $trimmed

        [void]$patterns.Add([PSCustomObject]@{
            Regex  = $regexPattern
            Negate = $negate
        })
    }

    return $patterns
}

# ============================================
# FUNCTION: Test if a relative path matches gitignore rules
# ============================================
function Test-GitignoreMatch {
    param(
        [string]$RelativePath,
        [array]$Patterns
    )

    $normalizedPath = $RelativePath -replace '\\', '/'
    $ignored = $false

    foreach ($p in $Patterns) {
        try {
            if ($normalizedPath -match $p.Regex) {
                $ignored = -not $p.Negate
            }
        } catch {
            continue
        }
    }

    return $ignored
}

# ============================================
# FUNCTION: Fast Recursive File Scanner
# ============================================
function Get-FilesRecursiveFast {
    param([string]$Path)

    $result = [System.Collections.ArrayList]::new()
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $currentDir = $stack.Pop()

        $files = @()
        try {
            $files = [System.IO.Directory]::EnumerateFiles($currentDir, "*", [System.IO.SearchOption]::TopDirectoryOnly)
        } catch {}

        foreach ($f in $files) {
            try {
                $fileInfo = [System.IO.FileInfo]::new($f)
                [void]$result.Add($fileInfo)
            } catch {}
        }

        $dirs = @()
        try {
            $dirs = [System.IO.Directory]::EnumerateDirectories($currentDir, "*", [System.IO.SearchOption]::TopDirectoryOnly)
        } catch {}

        $dirsArr = @($dirs)
        for ($i = $dirsArr.Length - 1; $i -ge 0; $i--) {
            $stack.Push($dirsArr[$i])
        }
    }

    return $result
}

# ============================================
# FUNCTION: Recent folders history helpers
# ============================================
function Get-RecentFoldersFilePath {
    $appData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) { $appData = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($appData)) { $appData = $env:TEMP }
    $dir = [System.IO.Path]::Combine($appData, "FileCompilerScript")
    if (-not (Test-Path $dir -PathType Container)) {
        try { New-Item -Path $dir -ItemType Directory -Force | Out-Null } catch {}
    }
    return [System.IO.Path]::Combine($dir, "recent_folders.json")
}

function Load-RecentFolders {
    $path = Get-RecentFoldersFilePath
    if (-not (Test-Path $path -PathType Leaf)) {
        return [System.Collections.Generic.List[string]]::new()
    }
    try {
        $json = Get-Content -Path $path -Raw -Encoding UTF8
        $data = $json | ConvertFrom-Json
        $list = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $data -and $null -ne $data.Folders) {
            foreach ($item in $data.Folders) { 
                $list.Add([string]$item.Path) 
            }
        }
        return $list
    } catch {
        return [System.Collections.Generic.List[string]]::new()
    }
}

function Save-RecentFolder {
    param([string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder)) { return }
    $path = Get-RecentFoldersFilePath
    $current = Load-RecentFolders
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add($Folder)
    foreach ($item in $current) {
        if ($item -ne $Folder) { $list.Add($item) }
    }
    while ($list.Count -gt 10) { $list.RemoveAt($list.Count - 1) }
    try {
        $objList = @()
        foreach ($f in $list) {
            $objList += [PSCustomObject]@{ Path = $f }
        }
        $json = @{ Folders = $objList } | ConvertTo-Json -Depth 3 -Compress
        Set-Content -Path $path -Value $json -Encoding UTF8
    } catch {}
}

function Select-FolderWithRecent {
    param(
        [string]$Prompt
    )

    $recent = Load-RecentFolders

    if ($recent.Count -gt 0) {
        Write-Host ""
        Write-Host "Recent folders:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $recent.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $recent[$i]) -ForegroundColor Gray
        }
        Write-Host "  (Enter a number to reuse, 'b' to browse, or type a new path)" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host "  (Type a new path, or 'b' to browse)" -ForegroundColor DarkGray
    }

    do {
        $input = Read-Host $Prompt

        if ([string]::IsNullOrWhiteSpace($input)) {
            Write-Warning "Path cannot be empty. Please try again."
            continue
        }

        if ($input -match '^[bB]$') {
            Add-Type -AssemblyName System.Windows.Forms
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fbd.Description = "Select folder"
            $fbd.ShowNewFolderButton = $true
            if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                return $fbd.SelectedPath
            }
            continue
        }

        if ($input -match '^\d+$') {
            $idx = [int]$input
            if ($idx -ge 1 -and $idx -le $recent.Count) {
                return $recent[$idx - 1]
            } else {
                Write-Warning "Invalid selection number. Please try again."
                continue
            }
        }

        return $input
    } while ($true)
}

# ============================================
# FUNCTION: Tree-style file listing (Manual / Display Only)
# ============================================
function Render-TreeNode {
    param(
        $Node,
        [string]$Prefix
    )

    $folderNames = @($Node.Folders.Keys | Sort-Object)
    $files = @($Node.Files | Sort-Object Name)

    $entries = [System.Collections.ArrayList]::new()
    foreach ($f in $folderNames) {
        [void]$entries.Add([PSCustomObject]@{ Type = 'Folder'; Name = $f; Node = $Node.Folders[$f] })
    }
    foreach ($f in $files) {
        [void]$entries.Add([PSCustomObject]@{ Type = 'File'; Name = $f.Name; Data = $f })
    }

    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        $isLast = ($i -eq $entries.Count - 1)
        $connector = if ($isLast) { '└── ' } else { '├── ' }
        $childPrefix = if ($isLast) { '    ' } else { '│   ' }

        if ($entry.Type -eq 'Folder') {
            Write-Host "$Prefix$connector$($entry.Name)/" -ForegroundColor DarkCyan
            Render-TreeNode -Node $entry.Node -Prefix ($Prefix + $childPrefix)
        } else {
            $f = $entry.Data
            $sizeStr = if ($f.Size -lt 1KB) { "$($f.Size) B" }
                       elseif ($f.Size -lt 1MB) { "{0:N2} KB" -f ($f.Size / 1KB) }
                       else { "{0:N2} MB" -f ($f.Size / 1MB) }
            Write-Host ("$Prefix$connector[{0,3}] {1} ({2})" -f $f.Number, $f.Name, $sizeStr)
        }
    }
}

function Show-FileTree {
    param(
        [array]$Files,
        [string]$BasePath
    )

    $root = @{ Folders = @{}; Files = [System.Collections.ArrayList]::new() }
    $num = 0
    foreach ($file in $Files) {
        $num++
        $rel = $file.FullName.Substring($BasePath.Length).TrimStart('\', '/')
        $parts = $rel -split '[/\\]'
        $current = $root
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $part = $parts[$i]
            if (-not $current.Folders.ContainsKey($part)) {
                $current.Folders[$part] = @{ Folders = @{}; Files = [System.Collections.ArrayList]::new() }
            }
            $current = $current.Folders[$part]
        }
        $leaf = $parts[$parts.Count - 1]
        [void]$current.Files.Add([PSCustomObject]@{
            Number = $num
            Name   = $leaf
            Size   = $file.Length
            File   = $file
        })
    }

    Write-Host "  (root)" -ForegroundColor DarkCyan
    Render-TreeNode -Node $root -Prefix "  "
}

# ============================================
# FUNCTION: Interactive Arrow-Key Selection UI
# ============================================
function Select-FilesInteractive {
    param(
        [array]$Files,
        [string]$BasePath
    )

    $root = @{ Type='Root'; Name=''; Depth=0; Expanded=$true; Children=[System.Collections.ArrayList]::new(); File=$null; Selected=$false }
    $num = 0
    foreach($f in $Files) {
        $num++
        $rel = $f.FullName.Substring($BasePath.Length).TrimStart('\','/')
        $parts = $rel -split '[/\\]'
        $current = $root
        for($i=0; $i -lt $parts.Count - 1; $i++) {
            $part = $parts[$i]
            $found = $false
            foreach($child in $current.Children) { 
                if($child.Name -eq $part -and $child.Type -eq 'Folder') { 
                    $current = $child; $found=$true; break 
                } 
            }
            if(-not $found) {
                $newFolder = @{ Type='Folder'; Name=$part; Depth=$current.Depth+1; Expanded=$true; Children=[System.Collections.ArrayList]::new(); File=$null; Selected=$false }
                [void]$current.Children.Add($newFolder)
                $current = $newFolder
            }
        }
        $leaf = $parts[$parts.Count-1]
        $newFile = @{ Type='File'; Name=$leaf; Depth=$current.Depth+1; Expanded=$false; Children=@(); File=$f; Selected=$false; Number=$num }
        [void]$current.Children.Add($newFile)
    }

    $cursorIndex = 0
    $running = $true
    $prevMaxLines = 0

    function Get-VisibleNodes {
        param($Node)
        $visible = [System.Collections.ArrayList]::new()
        $stack = [System.Collections.Stack]::new()
        
        $children = $Node.Children | Sort-Object @{Expression='Type'; Descending=$true}, Name
        $arr = @($children)
        for ($c = $arr.Length - 1; $c -ge 0; $c--) {
            $stack.Push(@{Node=$arr[$c]; Depth=1})
        }

        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            [void]$visible.Add($item)
            if ($item.Node.Type -eq 'Folder' -and $item.Node.Expanded) {
                $subChildren = $item.Node.Children | Sort-Object @{Expression='Type'; Descending=$true}, Name
                $subArr = @($subChildren)
                for ($s = $subArr.Length - 1; $s -ge 0; $s--) {
                    $stack.Push(@{Node=$subArr[$s]; Depth=($item.Depth+1)})
                }
            }
        }
        return $visible
    }

    function Toggle-NodeState {
        param($Node, $State)
        $Node.Selected = $State
        if ($Node.Type -eq 'Folder' -or $Node.Type -eq 'Root') {
            foreach($c in $Node.Children) { Toggle-NodeState -Node $c -State $State }
        }
    }

    while ($running) {
        [Console]::CursorVisible = $false
        [Console]::SetCursorPosition(0, 0)
        Write-Host "Interactive File Selection" -ForegroundColor Cyan
        Write-Host "[Up/Down] Navigate  [Space] Toggle  [Left/Right] Collapse/Expand  [A] Select All  [Enter] Confirm  [Esc] Cancel" -ForegroundColor DarkGray
        
        $visible = Get-VisibleNodes -Node $root
        
        $lineIdx = 2
        for($i=0; $i -lt $visible.Count; $i++) {
            $n = $visible[$i].Node
            $depth = $visible[$i].Depth
            $indent = "    " * $depth
            
            if($i -eq $cursorIndex) { $bg = "DarkGray"; $fg = "White" } else { $bg = "Black"; $fg = "Gray" }
            
            $lineText = ""
            if($n.Type -eq 'Folder') {
                $expMark = if($n.Expanded) { "[-]" } else { "[+]" }
                $selMark = if($n.Selected) { "[*]" } else { "[ ]" }
                $lineText = "$indent$selMark$expMark $($n.Name)/"
            } else {
                $selMark = if($n.Selected) { "[*]" } else { "[ ]" }
                $lineText = "$indent$selMark    [$($n.Number)] $($n.Name)"
            }
            
            $paddedLine = $lineText.PadRight([Console]::WindowWidth - 1)
            [Console]::SetCursorPosition(0, $lineIdx)
            Write-Host $paddedLine -ForegroundColor $fg -BackgroundColor $bg -NoNewline
            $lineIdx++
        }

        # Clear trailing lines if list shrank
        for($i=$lineIdx; $i -lt $prevMaxLines + 2; $i++) {
            [Console]::SetCursorPosition(0, $i)
            Write-Host "".PadRight([Console]::WindowWidth - 1) -NoNewline
        }
        $prevMaxLines = $visible.Count

        $key = [Console]::ReadKey($true)
        $currentNode = $visible[$cursorIndex].Node
        
        switch($key.Key) {
            'UpArrow' { if($cursorIndex -gt 0) { $cursorIndex-- } }
            'DownArrow' { if($cursorIndex -lt $visible.Count - 1) { $cursorIndex++ } }
            'LeftArrow' { if($currentNode.Type -eq 'Folder') { $currentNode.Expanded = $false } }
            'RightArrow' { if($currentNode.Type -eq 'Folder') { $currentNode.Expanded = $true } }
            'Spacebar' {
                if($currentNode.Type -eq 'File') {
                    $currentNode.Selected = -not $currentNode.Selected
                } elseif($currentNode.Type -eq 'Folder') {
                    $newState = -not $currentNode.Selected
                    Toggle-NodeState -Node $currentNode -State $newState
                }
            }
            'A' {
                $newState = -not ($visible | Where-Object { $_.Node.Type -eq 'File' } | Select-Object -First 1).Node.Selected
                Toggle-NodeState -Node $root -State $newState
            }
            'Enter' { $running = $false }
            'Escape' { 
                [Console]::CursorVisible = $true
                [Console]::SetCursorPosition(0, $prevMaxLines + 3)
                return $null 
            }
        }
    }

    [Console]::CursorVisible = $true
    [Console]::SetCursorPosition(0, $prevMaxLines + 3)

    $selectedFiles = [System.Collections.ArrayList]::new()
    function Get-SelectedRecursive {
        param($Node)
        if($Node.Type -eq 'File' -and $Node.Selected) { [void]$selectedFiles.Add($Node.File) }
        elseif($Node.Type -eq 'Folder' -or $Node.Type -eq 'Root') {
            foreach($c in $Node.Children) { Get-SelectedRecursive -Node $c }
        }
    }
    Get-SelectedRecursive -Node $root
    return $selectedFiles
}

# ============================================
# FUNCTION: Show a multiline textbox popup for paste
# ============================================
function Show-ImportTextBox {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Paste Compiled Content (Plain Text or Markdown)"
    $form.Size = New-Object System.Drawing.Size(900, 650)
    $form.StartPosition = "CenterScreen"
    $form.MinimizeBox = $false

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ScrollBars = "Both"
    $textBox.WordWrap = $false
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $textBox.Dock = "Fill"
    $textBox.AcceptsTab = $true
    $textBox.AcceptsReturn = $true
    $textBox.MaxLength = 0
    $textBox.ShortcutsEnabled = $true

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = "Bottom"
    $panel.Height = 45

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Width = 120
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Width = 120
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $panel.Add_Resize({
        $okButton.Top = 8
        $cancelButton.Top = 8
        $okButton.Left = 20
        $cancelButton.Left = $panel.Width - $cancelButton.Width - 20
    })

    $panel.Controls.Add($okButton)
    $panel.Controls.Add($cancelButton)

    $form.Controls.Add($textBox)
    $form.Controls.Add($panel)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text
    }
    return $null
}

# ============================================
# FUNCTION: Parse compiled content into file blocks (Handles Plain & Markdown)
# ============================================
function Parse-CompiledContent {
    param(
        [string]$Content
    )

    $files = [System.Collections.ArrayList]::new()

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $files
    }

    $normalized = $Content -replace "`r`n", "`n"
    $lines = $normalized -split "`n"

    # Markdown Detection
    if ($Content -match '(?m)^```') {
        $i = 0
        $total = $lines.Count
        $blockIdx = 0
        while ($i -lt $total) {
            if ($lines[$i] -match '^```(.+)$') {
                $header = $matches[1].Trim()
                $path = ""
                
                if ($header -match '[/\\]') {
                    $path = $header
                } elseif ($header -match '^\w+$') {
                    $blockIdx++
                    $path = "unknown_$blockIdx.$header"
                } else {
                    $blockIdx++
                    $path = "unknown_$blockIdx.txt"
                }
                
                $i++
                $contentLines = [System.Collections.ArrayList]::new()
                while ($i -lt $total -and $lines[$i] -notmatch '^```') {
                    [void]$contentLines.Add($lines[$i])
                    $i++
                }
                
                while ($contentLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($contentLines[$contentLines.Count - 1])) {
                    $contentLines.RemoveAt($contentLines.Count - 1)
                }

                $fileContent = $contentLines -join "`r`n"
                [void]$files.Add([PSCustomObject]@{
                    Path    = $path
                    Content = $fileContent
                })
            }
            $i++
        }
    } else {
        # Plain Text Detection
        $i = 0
        $total = $lines.Count

        while ($i -lt $total) {
            $currentLine = $lines[$i]
            $nextLine = if (($i + 1) -lt $total) { $lines[$i + 1] } else { $null }

            if ($nextLine -ne $null -and
                $nextLine -match '^={3,}$' -and
                $currentLine -notmatch '^={3,}$') {

                $path = $currentLine.Trim()

                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $i += 2

                    $contentLines = [System.Collections.ArrayList]::new()

                    while ($i -lt $total) {
                        $cur = $lines[$i]
                        $nxt = if (($i + 1) -lt $total) { $lines[$i + 1] } else { $null }

                        if ($nxt -ne $null -and
                            $nxt -match '^={3,}$' -and
                            $cur -notmatch '^={3,}$') {
                            break
                        }

                        [void]$contentLines.Add($cur)
                        $i++
                    }

                    while ($contentLines.Count -gt 0 -and
                           [string]::IsNullOrWhiteSpace($contentLines[$contentLines.Count - 1])) {
                        $contentLines.RemoveAt($contentLines.Count - 1)
                    }

                    $fileContent = $contentLines -join "`r`n"

                    [void]$files.Add([PSCustomObject]@{
                        Path    = $path
                        Content = $fileContent
                    })
                    continue
                }
            }
            $i++
        }
    }

    return $files
}

# ============================================
# FUNCTION: Show the Diff Window
# ============================================
function Show-DiffWindow {
    param(
        [string]$FilePath,
        [string]$OriginalContent,
        [string]$NewContent
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $zws = [char]0x200B

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Diff Viewer - $FilePath"
    $form.Size = New-Object System.Drawing.Size(1400, 850)
    $form.StartPosition = "CenterScreen"
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false

    $splitContainer = New-Object System.Windows.Forms.SplitContainer
    $splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $splitContainer.Orientation = [System.Windows.Forms.Orientation]::Vertical

    $form.Add_Load({
        $splitContainer.SplitterDistance = [int]($splitContainer.ClientRectangle.Width / 2)
    })

    $panel1 = $splitContainer.Panel1
    $panel2 = $splitContainer.Panel2

    $lblOriginal = New-Object System.Windows.Forms.Label
    $lblOriginal.Text = "Original"
    $lblOriginal.Dock = [System.Windows.Forms.DockStyle]::Top
    $lblOriginal.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblOriginal.Height = 25
    $lblOriginal.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    $rtbOriginal = New-Object System.Windows.Forms.RichTextBox
    $rtbOriginal.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rtbOriginal.ReadOnly = $true
    $rtbOriginal.WordWrap = $false
    $rtbOriginal.Font = New-Object System.Drawing.Font("Consolas", 10)

    $panel1.Controls.Add($rtbOriginal)
    $panel1.Controls.Add($lblOriginal)

    $lblNew = New-Object System.Windows.Forms.Label
    $lblNew.Text = "New (Editable)"
    $lblNew.Dock = [System.Windows.Forms.DockStyle]::Top
    $lblNew.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblNew.Height = 25
    $lblNew.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

    $rtbNew = New-Object System.Windows.Forms.RichTextBox
    $rtbNew.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rtbNew.ReadOnly = $false
    $rtbNew.WordWrap = $false
    $rtbNew.Font = New-Object System.Drawing.Font("Consolas", 10)

    $panel2.Controls.Add($rtbNew)
    $panel2.Controls.Add($lblNew)

    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottomPanel.Height = 50

    $btnApprove = New-Object System.Windows.Forms.Button
    $btnApprove.Text = "Approve"
    $btnApprove.Size = New-Object System.Drawing.Size(100, 30)

    $btnApproveAll = New-Object System.Windows.Forms.Button
    $btnApproveAll.Text = "Approve All"
    $btnApproveAll.Size = New-Object System.Drawing.Size(100, 30)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)

    $bottomPanel.Controls.Add($btnApprove)
    $bottomPanel.Controls.Add($btnApproveAll)
    $bottomPanel.Controls.Add($btnCancel)

    $bottomPanel.Add_Resize({
        $btnCancel.Left = $bottomPanel.Width - $btnCancel.Width - 20
        $btnApproveAll.Left = $btnCancel.Left - $btnApproveAll.Width - 10
        $btnApprove.Left = $btnApproveAll.Left - $btnApprove.Width - 10
        $btnCancel.Top = 10
        $btnApproveAll.Top = 10
        $btnApprove.Top = 10
    })

    $form.Controls.Add($splitContainer)
    $form.Controls.Add($bottomPanel)

    $diffResult = [DiffGenerator]::Generate($OriginalContent, $NewContent)
    
    $rtbOriginal.Rtf = $diffResult.OriginalRtf
    $rtbNew.Rtf = $diffResult.NewRtf

    $rtbOriginal.SelectionStart = 0
    $rtbOriginal.SelectionLength = 0
    $rtbNew.SelectionStart = 0
    $rtbNew.SelectionLength = 0

    $isSyncing = $false
    $syncScroll = {
        if ($isSyncing) { return }
        $isSyncing = $true

        $source = $this
        $dest = if ($source -eq $rtbOriginal) { $rtbNew } else { $rtbOriginal }

        $firstLine = [Win32Scroll]::SendMessage($source.Handle, [Win32Scroll]::EM_GETFIRSTVISIBLELINE, 0, 0)
        $destFirstLine = [Win32Scroll]::SendMessage($dest.Handle, [Win32Scroll]::EM_GETFIRSTVISIBLELINE, 0, 0)
        $delta = $firstLine - $destFirstLine

        if ($delta -ne 0) {
            [Win32Scroll]::SendMessage($dest.Handle, [Win32Scroll]::EM_LINESCROLL, 0, $delta)
        }

        $isSyncing = $false
    }

    $rtbOriginal.Add_VScroll($syncScroll)
    $rtbNew.Add_VScroll($syncScroll)
    $rtbOriginal.Add_MouseWheel($syncScroll)
    $rtbNew.Add_MouseWheel($syncScroll)

    $state = @{ Result = "Cancel"; Content = $null }

    $extractContent = {
        $rawText = $rtbNew.Text
        $allLines = $rawText -split "`r`n|`n"
        $filtered = [System.Collections.Generic.List[string]]::new()
        foreach ($ln in $allLines) {
            # Drop alignment lines (zws marker or pipe-only gutter)
            if ($ln.Contains($zws)) { continue }
            if ($ln -match '^\s{1,4}\|\s*$') { continue }

            # Only keep lines with a line-number prefix; skip RTF artifacts
            if ($ln -match '^\s{0,4}\d+\|\s?(.*)$') {
                $filtered.Add($matches[1])
            }
        }
        # Trim trailing blank lines (matches export's TrimEnd behavior)
        while ($filtered.Count -gt 0 -and [string]::IsNullOrWhiteSpace($filtered[$filtered.Count - 1])) {
            $filtered.RemoveAt($filtered.Count - 1)
        }
        $joined = $filtered -join "`r`n"
        return $joined
    }

    $btnApprove.Add_Click({
        $state.Result = "Approve"
        $state.Content = & $extractContent
        $form.Close()
    })
    $btnApproveAll.Add_Click({
        $state.Result = "ApproveAll"
        $state.Content = & $extractContent
        $form.Close()
    })
    $btnCancel.Add_Click({
        $state.Result = "Cancel"
        $form.Close()
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    
    return $state
}

# ============================================
# FUNCTION: Import feature
# ============================================
function Invoke-ImportFeature {
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "   File Import Script" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""

    do {
        $folderPath = Select-FolderWithRecent -Prompt "Enter the destination folder location"

        if ([string]::IsNullOrWhiteSpace($folderPath)) {
            Write-Warning "Folder path cannot be empty. Please try again."
            continue
        }

        if (-not (Test-Path -Path $folderPath -PathType Container)) {
            $createIt = Read-YesNoPrompt -Prompt "Folder '$folderPath' does not exist. Create it?" -DefaultYes $true
            if ($createIt) {
                try {
                    New-Item -Path $folderPath -ItemType Directory -Force | Out-Null
                    break
                }
                catch {
                    Write-Warning "Failed to create folder: $_"
                    continue
                }
            }
            continue
        }

        break
    } while ($true)

    $folderPath = [System.IO.Path]::GetFullPath($folderPath).TrimEnd('\', '/')
    $baseFullPath = $folderPath

    Save-RecentFolder -Folder $baseFullPath

    Write-Host ""
    Write-Host "Opening text box for you to paste the compiled content..." -ForegroundColor Yellow
    Write-Host "Supports both Plain Text and Markdown formats." -ForegroundColor Yellow

    $pastedContent = Show-ImportTextBox

    if ($null -eq $pastedContent) {
        Write-Host ""
        Write-Host "Import cancelled by user." -ForegroundColor Yellow
        return
    }

    if ([string]::IsNullOrWhiteSpace($pastedContent)) {
        Write-Host ""
        Write-Host "No content provided. Import cancelled." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "Parsing pasted content..." -ForegroundColor Yellow

    $files = Parse-CompiledContent -Content $pastedContent

    if ($files.Count -eq 0) {
        Write-Host "No file blocks detected in the pasted content." -ForegroundColor Red
        return
    }

    Write-Host "Detected $($files.Count) file(s) in pasted content." -ForegroundColor Green
    
    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "   Files to Import" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    $fileStatuses = [System.Collections.ArrayList]::new()
    $useProgress = $files.Count -gt 25

    for ($i = 0; $i -lt $files.Count; $i++) {
        if ($useProgress) {
            $pct = [int](($i / $files.Count) * 100)
            Write-Progress -Activity "Analyzing files" -Status "Checking $i of $($files.Count)" -PercentComplete $pct
        }

        $relativePath = $files[$i].Path
        $targetPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($baseFullPath, $relativePath))
        
        $statusStr = ""
        $statusColor = [System.ConsoleColor]::White

        if (-not $targetPath.StartsWith($baseFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $statusStr = "[SKIP-OUTSIDE]"
            $statusColor = [System.ConsoleColor]::DarkRed
        } elseif (Test-Path -Path $targetPath -PathType Leaf) {
            $existingContent = [System.IO.File]::ReadAllText($targetPath, $utf8NoBom)
            if ($existingContent -eq $files[$i].Content) {
                $statusStr = "[UNCHANGED]"
                $statusColor = [System.ConsoleColor]::DarkGray
            } else {
                $statusStr = "[MODIFIED]"
                $statusColor = [System.ConsoleColor]::Yellow
            }
        } else {
            $statusStr = "[NEW]"
            $statusColor = [System.ConsoleColor]::Green
        }

        [void]$fileStatuses.Add([PSCustomObject]@{
            Index      = $i
            Path       = $relativePath
            Status     = $statusStr
            Color      = $statusColor
            TargetPath = $targetPath
        })

        Write-Host ("  [{0,3}] {1,-16} {2}" -f ($i + 1), $statusStr, $relativePath) -ForegroundColor $statusColor
    }

    if ($useProgress) {
        Write-Progress -Activity "Analyzing files" -Completed
    }

    $countNew      = ($fileStatuses | Where-Object { $_.Status -eq '[NEW]' }).Count
    $countModified = ($fileStatuses | Where-Object { $_.Status -eq '[MODIFIED]' }).Count
    $countUnchanged= ($fileStatuses | Where-Object { $_.Status -eq '[UNCHANGED]' }).Count
    $countOutside  = ($fileStatuses | Where-Object { $_.Status -eq '[SKIP-OUTSIDE]' }).Count

    Write-Host ""
    Write-Host "Diff Summary:" -ForegroundColor Cyan
    Write-Host "  New:       $countNew" -ForegroundColor Green
    Write-Host "  Modified:  $countModified" -ForegroundColor Yellow
    Write-Host "  Unchanged: $countUnchanged" -ForegroundColor DarkGray
    if ($countOutside -gt 0) {
        Write-Host "  Outside:   $countOutside" -ForegroundColor DarkRed
    }
    Write-Host ""

    $createBackups = $false
    if ($countModified -gt 0) {
        $createBackups = Read-YesNoPrompt -Prompt "Create .bak backups of files that will be replaced?" -DefaultYes $false
        if ($createBackups) {
            Write-Host "Backups will be created as <filename>.bak before overwriting." -ForegroundColor Green
        }
    }

    $confirm = Read-YesNoPrompt -Prompt "Proceed with import?" -DefaultYes $true
    if (-not $confirm) {
        Write-Host "Import cancelled." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Importing files..." -ForegroundColor Yellow

    $replaceAll = $false
    $imported = 0
    $skipped = 0
    $failed = 0
    $backedUp = 0
    $useImportProgress = $files.Count -gt 25
    $importIndex = 0

    foreach ($fileEntry in $files) {
        $importIndex++
        if ($useImportProgress) {
            $pct = [int](($importIndex / $files.Count) * 100)
            Write-Progress -Activity "Importing files" -Status "Processing $importIndex of $($files.Count): $($fileEntry.Path)" -PercentComplete $pct
        }

        $relativePath = $fileEntry.Path
        $content = $fileEntry.Content

        $combinedPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($baseFullPath, $relativePath))

        if (-not $combinedPath.StartsWith($baseFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "  [SKIP] Path '$relativePath' escapes destination folder. Skipping."
            $skipped++
            continue
        }

        $fullPath = $combinedPath
        $fileExists = Test-Path -Path $fullPath -PathType Leaf

        if ($fileExists) {
            $originalContent = [System.IO.File]::ReadAllText($fullPath, $utf8NoBom)

            if ($originalContent -eq $content) {
                Write-Host "  [UNCHANGED] $relativePath" -ForegroundColor DarkGray
                $skipped++
                continue
            }

            if (-not $replaceAll) {
                Write-Host "  Showing diff for: $relativePath" -ForegroundColor Cyan
                $dialogResult = Show-DiffWindow -FilePath $relativePath -OriginalContent $originalContent -NewContent $content

                if ($dialogResult.Result -eq "ApproveAll") {
                    $replaceAll = $true
                    $content = $dialogResult.Content
                    Write-Host "  [APPROVE ALL] All remaining files will be replaced automatically." -ForegroundColor Cyan
                } elseif ($dialogResult.Result -eq "Approve") {
                    $content = $dialogResult.Content
                } elseif ($dialogResult.Result -eq "Cancel") {
                    if ($useImportProgress) { Write-Progress -Activity "Importing files" -Completed }
                    Write-Host ""
                    Write-Host "Import aborted by user." -ForegroundColor Yellow
                    return
                }
            }

            if ($createBackups) {
                $bakPath = "$fullPath.bak"
                try {
                    Copy-Item -Path $fullPath -Destination $bakPath -Force
                    Write-Host "  [BACKUP]    $relativePath -> $([System.IO.Path]::GetFileName($bakPath))" -ForegroundColor DarkMagenta
                    $backedUp++
                }
                catch {
                    Write-Warning "  [BACKUP-FAILED] Could not back up '$relativePath': $_"
                }
            }
        }

        try {
            $parentDir = [System.IO.Path]::GetDirectoryName($fullPath)
            if (-not (Test-Path -Path $parentDir -PathType Container)) {
                New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
            }

            [System.IO.File]::WriteAllText($fullPath, $content, $utf8NoBom)

            if ($fileExists) {
                Write-Host "  [REPLACED] $relativePath" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [CREATED]  $relativePath" -ForegroundColor Green
            }
            $imported++
        }
        catch {
            Write-Warning "  [FAILED] Could not write '$relativePath': $_"
            $failed++
        }
    }

    if ($useImportProgress) {
        Write-Progress -Activity "Importing files" -Completed
    }

    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "Import complete!" -ForegroundColor Green
    Write-Host "  Created/Replaced: $imported" -ForegroundColor White
    Write-Host "  Skipped:          $skipped" -ForegroundColor White
    Write-Host "  Failed:           $failed" -ForegroundColor White
    if ($createBackups) {
        Write-Host "  Backups created:  $backedUp" -ForegroundColor White
    }
    Write-Host "  Destination:      $baseFullPath" -ForegroundColor White
    Write-Host "=====================================" -ForegroundColor Cyan
}

# ============================================
# FUNCTION: Export feature
# ============================================
function Invoke-ExportFeature {
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "   File Compiler Script (Recursive)" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""

    do {
        $folderPath = Select-FolderWithRecent -Prompt "Enter the folder location"

        if ([string]::IsNullOrWhiteSpace($folderPath)) {
            Write-Warning "Folder path cannot be empty. Please try again."
            continue
        }

        if (-not (Test-Path -Path $folderPath -PathType Container)) {
            Write-Warning "Folder '$folderPath' does not exist. Please try again."
            continue
        }

        break
    } while ($true)

    $folderPath = [System.IO.Path]::GetFullPath($folderPath).TrimEnd('\', '/')
    Save-RecentFolder -Folder $folderPath

    $useGitignore = $false
    $gitignorePatterns = @()
    $gitignorePath = [System.IO.Path]::Combine($folderPath, ".gitignore")

    if (Test-Path -Path $gitignorePath -PathType Leaf) {
        Write-Host ""
        Write-Host "Found a .gitignore file in this folder." -ForegroundColor Yellow
        $useGitignore = Read-YesNoPrompt -Prompt "Do you want to exclude files/folders matching .gitignore rules?" -DefaultYes $true

        if ($useGitignore) {
            $gitignorePatterns = Get-GitignorePatterns -GitignorePath $gitignorePath
            Write-Host "Loaded $($gitignorePatterns.Count) pattern(s) from .gitignore." -ForegroundColor Green
        }
    }

    $skipGitFolder = $false
    $gitFolderExists = Test-Path -Path ([System.IO.Path]::Combine($folderPath, ".git")) -PathType Container

    if ($gitFolderExists) {
        Write-Host ""
        Write-Host "Found a .git folder in this directory." -ForegroundColor Yellow
        $skipGitFolder = Read-YesNoPrompt -Prompt "Do you want to ignore all files within the .git folder?" -DefaultYes $true
        if ($skipGitFolder) {
            Write-Host "Files within the .git folder will be excluded." -ForegroundColor Green
        }
        else {
            Write-Host "Files within the .git folder will be included." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "Scanning folder (including subfolders): $folderPath" -ForegroundColor Yellow
    Write-Host "Checking file readability..." -ForegroundColor Yellow

    # Fast file scanning using .NET API
    $allFiles = Get-FilesRecursiveFast -Path $folderPath

    if ($null -eq $allFiles -or $allFiles.Count -eq 0) {
        Write-Host "No files found in the specified folder or its subfolders." -ForegroundColor Red
        return
    }

    Write-Host "Found $($allFiles.Count) total file(s). Filtering..." -ForegroundColor Yellow

    $readableFiles = [System.Collections.ArrayList]::new()
    $skippedByGitignore = 0
    $skippedByGitFolder = 0
    $skippedUnreadable = 0

    $useScanProgress = $allFiles.Count -gt 25
    $scanIndex = 0
    $totalAllCount = $allFiles.Count

    foreach ($file in $allFiles) {
        $scanIndex++
        if ($useScanProgress) {
            $pct = [int](($scanIndex / $totalAllCount) * 100)
            Write-Progress -Activity "Scanning files" -Status "Checking $scanIndex of $totalAllCount" -PercentComplete $pct
        }

        $relativePath = $file.FullName.Substring($folderPath.Length).TrimStart('\', '/')
        $normalizedRelPath = $relativePath -replace '\\', '/'

        if ($skipGitFolder -and ($normalizedRelPath -match '(^|/)\.git(/|$)')) {
            $skippedByGitFolder++
            continue
        }

        if ($useGitignore -and (Test-GitignoreMatch -RelativePath $normalizedRelPath -Patterns $gitignorePatterns)) {
            $skippedByGitignore++
            continue
        }

        if (-not (Test-IsReadableFile -FilePath $file.FullName)) {
            $skippedUnreadable++
            continue
        }

        [void]$readableFiles.Add($file)
    }

    if ($useScanProgress) {
        Write-Progress -Activity "Scanning files" -Completed
    }

    if ($skipGitFolder -and $skippedByGitFolder -gt 0) {
        Write-Host "  Skipped $skippedByGitFolder file(s) inside .git folder." -ForegroundColor DarkGray
    }
    if ($useGitignore -and $skippedByGitignore -gt 0) {
        Write-Host "  Skipped $skippedByGitignore file(s) matching .gitignore rules." -ForegroundColor DarkGray
    }
    if ($skippedUnreadable -gt 0) {
        Write-Host "  Skipped $skippedUnreadable unreadable/binary file(s)." -ForegroundColor DarkGray
    }

    if ($readableFiles.Count -eq 0) {
        Write-Host "No readable text files found after filtering." -ForegroundColor Red
        return
    }

    $readableFiles = $readableFiles | Sort-Object FullName

    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "   Available Readable Files (Tree)" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan

    Show-FileTree -Files $readableFiles -BasePath $folderPath

    Write-Host ""
    Write-Host "Total: $($readableFiles.Count) readable file(s) found across all subfolders." -ForegroundColor Green
    Write-Host ""

    Write-Host "Choose selection method:" -ForegroundColor Cyan
    Write-Host "  1. Interactive Tree (Arrow keys, Space to select, Enter to confirm)"
    Write-Host "  2. Manual Numbers (e.g., '1-5 7 10-15')"
    $methodChoice = ""
    do {
        $methodChoice = Read-Host "Enter choice (1 or 2)"
        if ($methodChoice -in '1', '2') { break }
        Write-Warning "Invalid choice. Please enter 1 or 2."
    } while ($true)

    $selectedFiles = @()
    if ($methodChoice -eq '1') {
        Write-Host ""
        Write-Host "Launching interactive view..." -ForegroundColor Yellow
        $selectedFiles = Select-FilesInteractive -Files $readableFiles -BasePath $folderPath
        if ($null -eq $selectedFiles) {
            Write-Host "Selection cancelled." -ForegroundColor Yellow
            return
        }
        if ($selectedFiles.Count -eq 0) {
            Write-Host "No files were selected." -ForegroundColor Yellow
            return
        }
    } else {
        Write-Host "Enter file numbers to compile." -ForegroundColor Yellow
        Write-Host "Examples: '1 2 3 4 5 7'  or  '1-5 7'  or  '1-3 5-7 10'" -ForegroundColor Gray

        do {
            $selectionInput = Read-Host "Selection"

            if ([string]::IsNullOrWhiteSpace($selectionInput)) {
                Write-Warning "Selection cannot be empty. Please try again."
                continue
            }

            $selectedIndices = Get-SelectedIndices -SelectionString $selectionInput -MaxIndex $readableFiles.Count

            if ($selectedIndices.Count -eq 0) {
                Write-Warning "No valid file numbers selected. Please try again."
                continue
            }

            break
        } while ($true)

        foreach ($idx in $selectedIndices) {
            $selectedFiles += $readableFiles[$idx - 1]
        }
    }

    Write-Host ""
    Write-Host "You selected the following files:" -ForegroundColor Green
    foreach ($file in $selectedFiles) {
        $relativePath = $file.FullName.Substring($folderPath.Length).TrimStart('\', '/')
        Write-Host "  - $relativePath"
    }

    Write-Host ""
    $confirm = Read-YesNoPrompt -Prompt "Proceed with compilation?" -DefaultYes $true
    if (-not $confirm) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Choose output format:" -ForegroundColor Cyan
    Write-Host "  1. Plain Text (Default headers with '===')"
    Write-Host "  2. Markdown / AI-Ready (```path/code blocks)"
    do {
        $formatChoice = Read-Host "Enter choice (1 or 2)"
        if ($formatChoice -in '1', '2') { break }
        Write-Warning "Invalid choice. Please enter 1 or 2."
    } while ($true)

    $isMarkdown = ($formatChoice -eq '2')
    Write-Host ""
    Write-Host "Compiling files..." -ForegroundColor Yellow

    $compiledContent = [System.Text.StringBuilder]::new()
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    $useCompileProgress = $selectedFiles.Count -gt 25
    $compileIndex = 0
    $totalSelected = $selectedFiles.Count

    if ($isMarkdown) {
        foreach ($file in $selectedFiles) {
            $compileIndex++
            if ($useCompileProgress) {
                $pct = [int](($compileIndex / $totalSelected) * 100)
                Write-Progress -Activity "Compiling files (Markdown)" -Status "Processing $compileIndex of $totalSelected" -PercentComplete $pct
            }

            try {
                $content = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom)
                $relativePath = $file.FullName.Substring($folderPath.Length).TrimStart('\', '/')

                [void]$compiledContent.AppendLine("``````$relativePath")
                if ($null -ne $content) {
                    [void]$compiledContent.AppendLine($content.TrimEnd())
                }
                [void]$compiledContent.AppendLine("``````")
                [void]$compiledContent.AppendLine()

                Write-Host "  [OK] Added (MD): $relativePath" -ForegroundColor Green
            }
            catch {
                Write-Warning "  [FAILED] Could not read '$($file.Name)': $_"
            }
        }
    } else {
        $separator = "=" * 60
        foreach ($file in $selectedFiles) {
            $compileIndex++
            if ($useCompileProgress) {
                $pct = [int](($compileIndex / $totalSelected) * 100)
                Write-Progress -Activity "Compiling files (Plain)" -Status "Processing $compileIndex of $totalSelected" -PercentComplete $pct
            }

            try {
                $content = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom)
                $relativePath = $file.FullName.Substring($folderPath.Length).TrimStart('\', '/')

                [void]$compiledContent.AppendLine($relativePath)
                [void]$compiledContent.AppendLine($separator)

                if ($null -ne $content) {
                    [void]$compiledContent.AppendLine($content.TrimEnd())
                }

                [void]$compiledContent.AppendLine()
                [void]$compiledContent.AppendLine()

                Write-Host "  [OK] Added: $relativePath" -ForegroundColor Green
            }
            catch {
                Write-Warning "  [FAILED] Could not read '$($file.Name)': $_"
            }
        }
    }

    if ($useCompileProgress) {
        Write-Progress -Activity "Compiling files" -Completed
    }

    $compiledString = $compiledContent.ToString()
    $sizeMB = [math]::Round($compiledString.Length / 1MB, 2)

    Write-Host ""
    Write-Host "Compilation complete. Choose export method:" -ForegroundColor Cyan
    Write-Host "  1. Copy to Clipboard"
    Write-Host "  2. Export as File"
    Write-Host "  3. Both"
    Write-Host ""

    $forceFile = $false
    if ($sizeMB -gt 4) {
        Write-Warning "Compiled content is $sizeMB MB. Windows Clipboard may truncate or hang with strings > 4MB."
        $continueClipboard = Read-YesNoPrompt -Prompt "Attempt to copy to clipboard anyway?" -DefaultYes $false
        if (-not $continueClipboard) {
            $forceFile = $true
            Write-Host "Export method forced to File." -ForegroundColor Yellow
        }
    }

    do {
        $exportChoice = Read-Host "Enter choice (1-3)"
        if ($forceFile -and $exportChoice -ne '2') { $exportChoice = '2'; break }
        if ($exportChoice -in '1', '2', '3') { break }
        Write-Warning "Invalid choice. Please enter 1, 2, or 3."
    } while ($true)

    $fileWritten = $false
    $clipboardCopied = $false
    $defaultExt = if ($isMarkdown) { ".md" } else { ".txt" }

    if ($exportChoice -eq '2' -or $exportChoice -eq '3') {
        $defaultOutputName = "Compiled_$(Get-Date -Format 'yyyyMMdd_HHmmss')$defaultExt"
        $outputFileName = Read-Host "Enter output file name (press Enter for default: $defaultOutputName)"

        if ([string]::IsNullOrWhiteSpace($outputFileName)) {
            $outputFileName = $defaultOutputName
        }

        if (-not [System.IO.Path]::HasExtension($outputFileName)) {
            $outputFileName += $defaultExt
        }

        if ([System.IO.Path]::IsPathRooted($outputFileName)) {
            $outputPath = $outputFileName
        } else {
            $outputPath = [System.IO.Path]::Combine($folderPath, $outputFileName)
        }

        try {
            $outDir = [System.IO.Path]::GetDirectoryName($outputPath)
            if (-not (Test-Path -Path $outDir -PathType Container)) {
                New-Item -Path $outDir -ItemType Directory -Force | Out-Null
            }

            [System.IO.File]::WriteAllText($outputPath, $compiledString, $utf8NoBom)
            Write-Host "[FILE] Compiled file created at: $outputPath" -ForegroundColor Green
            $fileWritten = $true
        }
        catch {
            Write-Host "ERROR: Failed to write output file: $_" -ForegroundColor Red
        }
    }

    if ($exportChoice -eq '1' -or $exportChoice -eq '3') {
        try {
            Set-Clipboard -Value $compiledString
            Write-Host "[CLIPBOARD] Compiled content copied to clipboard." -ForegroundColor Green
            $clipboardCopied = $true
        }
        catch {
            Write-Host "ERROR: Failed to copy to clipboard: $_" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "Export complete!" -ForegroundColor Green
    if ($fileWritten) {
        Write-Host "  File:      Written" -ForegroundColor White
    }
    if ($clipboardCopied) {
        Write-Host "  Clipboard: Copied" -ForegroundColor White
    }
    Write-Host "  Format:    $(if($isMarkdown){'Markdown'}else{'Plain Text'})" -ForegroundColor White
    Write-Host "  Files compiled: $($selectedFiles.Count)" -ForegroundColor White
    Write-Host "=====================================" -ForegroundColor Cyan
}

# ============================================
# MAIN SCRIPT
# ============================================

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "   File Compiler / Importer Script" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Select an option:"
Write-Host "  1. Export - Compile multiple files into one output"
Write-Host "  2. Import - Extract files from compiled content"
Write-Host ""

do {
    $modeChoice = Read-Host "Enter choice (1 or 2)"

    if ($modeChoice -eq '1') {
        $mode = 'Export'
        break
    }
    elseif ($modeChoice -eq '2') {
        $mode = 'Import'
        break
    }
    else {
        Write-Warning "Invalid choice. Please enter 1 or 2."
    }
} while ($true)

Write-Host ""
Write-Host "Mode selected: $mode" -ForegroundColor Green
Write-Host ""

if ($mode -eq 'Import') {
    Invoke-ImportFeature
}
else {
    Invoke-ExportFeature
}