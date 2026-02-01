## Visual Debugger for Nimmy scripts.
## A graphical step-by-step debugger using Silky UI.

import
  std/[os, strformat, strutils, tables, sets, hashes],
  opengl, windy, bumpy, vmath, chroma,
  silky, silky/widgets,
  ../../src/nimmy/[types, parser, vm, utils]

# =============================================================================
# Atlas Setup
# =============================================================================

let builder = newAtlasBuilder(1024, 4)
builder.addDir("data/", "data/")
builder.addFont("data/IBMPlexSans-Regular.ttf", "H1", 24.0)
builder.addFont("data/IBMPlexSans-Regular.ttf", "Default", 16.0)
builder.addFont("data/IBMPlexSans-Regular.ttf", "Code", 14.0)
builder.write("dist/atlas.png", "dist/atlas.json")

# =============================================================================
# Window Setup
# =============================================================================

let window = newWindow(
  "Nimmy Visual Debugger",
  ivec2(1400, 900),
  vsync = true
)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky("dist/atlas.png", "dist/atlas.json")

proc snapToPixels(rect: Rect): Rect =
  rect(rect.x.int.float32, rect.y.int.float32, rect.w.int.float32, rect.h.int.float32)

# =============================================================================
# Panel System Types
# =============================================================================

type
  AreaLayout = enum
    Horizontal
    Vertical

  PanelKind = enum
    pkSourceCode
    pkStackTrace
    pkOutput
    pkVariables
    pkControls

  Area = ref object
    layout: AreaLayout
    areas: seq[Area]
    panels: seq[Panel]
    split: float32
    selectedPanelNum: int
    rect: Rect

  Panel = ref object
    name: string
    kind: PanelKind
    parentArea: Area

  AreaScan = enum
    Header
    Body
    North
    South
    East
    West

# =============================================================================
# Debugger State
# =============================================================================

type
  OutputLine = object
    text: string
    isError: bool
  
  DebuggerState = ref object
    scriptPath: string
    source: string
    sourceLines: seq[string]
    ast: Node
    vm: VM
    running: bool
    outputLines: seq[OutputLine]
    hasError: bool  # Whether there's a fatal error (syntax/runtime)

var debugState: DebuggerState

# Forward declarations for scroll functions (defined after panel globals)
proc ensureCurrentLineVisible()
proc scrollOutputToBottom()
proc requestScrollToLine(line: int)

proc addOutput(text: string, isError: bool = false) =
  ## Add an output line
  if debugState != nil:
    debugState.outputLines.add(OutputLine(text: text, isError: isError))
    scrollOutputToBottom()

proc addError(text: string) =
  ## Add an error output line
  addOutput(text, isError = true)
  if debugState != nil:
    debugState.hasError = true

proc syncOutput() =
  ## Sync output from VM to debugState
  if debugState == nil or debugState.vm == nil:
    return
  let hadOutput = debugState.outputLines.len
  if debugState.vm.output.len > 0:
    # Count how many VM outputs we've already synced
    var vmSynced = 0
    for line in debugState.outputLines:
      if not line.isError:
        vmSynced += 1
    # Add new VM outputs
    for i in vmSynced ..< debugState.vm.output.len:
      debugState.outputLines.add(OutputLine(text: debugState.vm.output[i], isError: false))
  # Auto-scroll to bottom if new output was added
  if debugState.outputLines.len > hadOutput:
    scrollOutputToBottom()

proc initDebugger(scriptPath: string) =
  # Preserve breakpoints across restarts
  var oldBreakpoints: HashSet[int]
  if debugState != nil and debugState.vm != nil:
    oldBreakpoints = debugState.vm.breakpoints

  debugState = DebuggerState(
    scriptPath: scriptPath,
    running: false,
    outputLines: @[],
    hasError: false
  )

  if not fileExists(scriptPath):
    debugState.source = "# Error: File not found: " & scriptPath
    debugState.sourceLines = @[debugState.source]
    addError("Error: File not found: " & scriptPath)
    return

  debugState.source = readFile(scriptPath)
  debugState.sourceLines = debugState.source.splitLines()
  
  # Try to parse - catch syntax errors
  try:
    debugState.ast = parse(debugState.source)
  except NimmyError as e:
    addError("Syntax Error: " & e.msg)
    return
  except CatchableError as e:
    addError("Parse Error: " & e.msg)
    return
  
  debugState.vm = newVM()

  # Register minimal built-ins
  debugState.vm.addProc("len") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "len() takes exactly 1 argument")
    case args[0].kind
    of vkString: intValue(args[0].strVal.len)
    of vkArray: intValue(args[0].arrayVal.len)
    of vkTable: intValue(args[0].tableVal.len)
    else: raise newException(RuntimeError, "Cannot get length of " & typeName(args[0]))

  debugState.vm.addProc("str") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "str() takes exactly 1 argument")
    stringValue($args[0])

  debugState.vm.addProc("add") do (args: seq[Value]) -> Value:
    if args.len != 2:
      raise newException(RuntimeError, "add() takes exactly 2 arguments")
    if args[0].kind != vkArray:
      raise newException(RuntimeError, "First argument to add() must be an array")
    args[0].arrayVal.add(args[1])
    args[0]

  debugState.vm.addProc("pop") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "pop() takes exactly 1 argument")
    if args[0].kind != vkArray:
      raise newException(RuntimeError, "Argument to pop() must be an array")
    if args[0].arrayVal.len == 0:
      raise newException(RuntimeError, "Cannot pop from empty array")
    args[0].arrayVal.pop()

  # Load the AST into the VM for step-based execution
  debugState.vm.load(debugState.ast)
  
  # Restore breakpoints
  for bp in oldBreakpoints:
    debugState.vm.addBreakpoint(bp)
  
  debugState.running = true
  
  # Scroll to the first line
  requestScrollToLine(1)

proc toggleBreakpoint(line: int) =
  if debugState == nil or debugState.vm == nil:
    return
  if debugState.vm.hasBreakpoint(line):
    debugState.vm.removeBreakpoint(line)
  else:
    debugState.vm.addBreakpoint(line)

proc stepDebugger() =
  ## Single step - execute one statement (step over)
  if debugState == nil or debugState.vm == nil or debugState.vm.isFinished or debugState.hasError:
    return
  try:
    debugState.vm.stepOver()
    syncOutput()
    ensureCurrentLineVisible()
  except NimmyError as e:
    addError("Runtime Error: " & e.msg)

proc stepIntoDebugger() =
  ## Step into - steps into function calls
  if debugState == nil or debugState.vm == nil or debugState.vm.isFinished or debugState.hasError:
    return
  try:
    debugState.vm.stepInto()
    syncOutput()
    ensureCurrentLineVisible()
  except NimmyError as e:
    addError("Runtime Error: " & e.msg)

proc stepOutDebugger() =
  ## Step out - run until we exit the current function
  if debugState == nil or debugState.vm == nil or debugState.vm.isFinished or debugState.hasError:
    return
  try:
    debugState.vm.stepOut()
    syncOutput()
    ensureCurrentLineVisible()
  except NimmyError as e:
    addError("Runtime Error: " & e.msg)

proc continueDebugger() =
  ## Continue execution until breakpoint or end
  if debugState == nil or debugState.vm == nil or debugState.vm.isFinished or debugState.hasError:
    return
  try:
    debugState.vm.continueExecution()
    syncOutput()
    ensureCurrentLineVisible()
  except NimmyError as e:
    addError("Runtime Error: " & e.msg)

# =============================================================================
# Panel Constants
# =============================================================================

const
  AreaHeaderHeight = 32.0
  AreaMargin = 6.0
  LineNumberWidth = 50.0'f32
  BackgroundColor = parseHtmlColor("#1e1e2e").rgbx
  CurrentLineColor = parseHtmlColor("#44475a").rgbx
  BreakpointColor = parseHtmlColor("#ff5555").rgbx
  BreakpointLineColor = parseHtmlColor("#442222").rgbx
  LineNumberColor = parseHtmlColor("#6272a4").rgbx
  CodeColor = parseHtmlColor("#f8f8f2").rgbx
  DimTextColor = rgbx(128, 128, 128, 255)
  SuccessColor = rgbx(100, 200, 100, 255)
  ButtonColor = parseHtmlColor("#44475a").rgbx
  ButtonHoverColor = parseHtmlColor("#6272a4").rgbx

# =============================================================================
# Panel System Globals
# =============================================================================

var
  rootArea: Area
  dragArea: Area
  dragPanel: Panel
  dropHighlight: Rect
  showDropHighlight: bool
  maybeDragStartPos: Vec2
  maybeDragPanel: Panel
  # Global references to specific panels for auto-scroll
  gSourceCodePanel: Panel
  gOutputPanel: Panel

# =============================================================================
# Auto-Scroll State
# =============================================================================

# Scroll margin - when the current line is within this distance from the edge, scroll
const ScrollMargin = 80.0'f32

# Scroll requests - these are applied during drawing when we have access to font metrics
var scrollToLineRequest: int = 0      # Line number to scroll to (0 = no request)
var scrollOutputToBottomRequest: bool = false  # Whether to scroll output to bottom

proc requestScrollToLine(line: int) =
  ## Request scrolling to make a specific line visible
  scrollToLineRequest = line

proc requestScrollOutputToBottom() =
  ## Request scrolling output panel to bottom
  scrollOutputToBottomRequest = true

# These are called from debug functions
proc ensureCurrentLineVisible() =
  if debugState != nil and debugState.vm != nil:
    requestScrollToLine(debugState.vm.currentLine)

proc scrollOutputToBottom() =
  requestScrollOutputToBottom()

# =============================================================================
# Panel Logic
# =============================================================================

proc movePanels*(area: Area, panels: seq[Panel])

proc clear*(area: Area) =
  for panel in area.panels:
    panel.parentArea = nil
  for subarea in area.areas:
    subarea.clear()
  area.panels.setLen(0)
  area.areas.setLen(0)

proc removeBlankAreas*(area: Area) =
  if area.areas.len > 0:
    assert area.areas.len == 2
    if area.areas[0].panels.len == 0 and area.areas[0].areas.len == 0:
      if area.areas[1].panels.len > 0:
        area.movePanels(area.areas[1].panels)
        area.areas.setLen(0)
      elif area.areas[1].areas.len > 0:
        let oldAreas = area.areas
        area.areas = area.areas[1].areas
        area.split = oldAreas[1].split
        area.layout = oldAreas[1].layout
    elif area.areas[1].panels.len == 0 and area.areas[1].areas.len == 0:
      if area.areas[0].panels.len > 0:
        area.movePanels(area.areas[0].panels)
        area.areas.setLen(0)
      elif area.areas[0].areas.len > 0:
        let oldAreas = area.areas
        area.areas = area.areas[0].areas
        area.split = oldAreas[0].split
        area.layout = oldAreas[0].layout

    for subarea in area.areas:
      removeBlankAreas(subarea)

proc addPanel*(area: Area, name: string, kind: PanelKind): Panel =
  result = Panel(name: name, kind: kind, parentArea: area)
  area.panels.add(result)

proc movePanel*(area: Area, panel: Panel) =
  let idx = panel.parentArea.panels.find(panel)
  if idx != -1:
    panel.parentArea.panels.delete(idx)
  area.panels.add(panel)
  panel.parentArea = area

proc insertPanel*(area: Area, panel: Panel, index: int) =
  let idx = panel.parentArea.panels.find(panel)
  var finalIndex = index

  if panel.parentArea == area and idx != -1:
    if idx < index:
      finalIndex = index - 1

  if idx != -1:
    panel.parentArea.panels.delete(idx)

  finalIndex = clamp(finalIndex, 0, area.panels.len)
  area.panels.insert(panel, finalIndex)
  panel.parentArea = area
  area.selectedPanelNum = finalIndex

proc getTabInsertInfo(area: Area, mousePos: Vec2): (int, Rect) =
  var x = area.rect.x + 4
  let headerH = AreaHeaderHeight

  if area.panels.len == 0:
    return (0, rect(x, area.rect.y + 4, 4, headerH - 4))

  var bestIndex = 0
  var minDist = float32.high
  var bestX = x

  let dist0 = abs(mousePos.x - x)
  minDist = dist0
  bestX = x
  bestIndex = 0

  for i, panel in area.panels:
    let textSize = sk.getTextSize("Default", panel.name)
    let tabW = textSize.x + 16
    let gapX = x + tabW + 2
    let dist = abs(mousePos.x - gapX)
    if dist < minDist:
      minDist = dist
      bestIndex = i + 1
      bestX = gapX
    x += tabW + 2

  return (bestIndex, rect(bestX - 2, area.rect.y + 4, 4, headerH - 4))

proc movePanels*(area: Area, panels: seq[Panel]) =
  var panelList = panels
  for panel in panelList:
    area.movePanel(panel)

proc split*(area: Area, layout: AreaLayout) =
  let
    area1 = Area(rect: area.rect)
    area2 = Area(rect: area.rect)
  area.layout = layout
  area.split = 0.5
  area.areas.add(area1)
  area.areas.add(area2)

proc scan*(area: Area): (Area, AreaScan, Rect) =
  let mousePos = window.mousePos.vec2
  var
    targetArea: Area
    areaScan: AreaScan
    resRect: Rect

  proc visit(area: Area) =
    if not mousePos.overlaps(area.rect):
      return

    if area.areas.len > 0:
      for subarea in area.areas:
        visit(subarea)
    else:
      let
        headerRect = rect(area.rect.xy, vec2(area.rect.w, AreaHeaderHeight))
        bodyRect = rect(area.rect.xy + vec2(0, AreaHeaderHeight), vec2(area.rect.w, area.rect.h - AreaHeaderHeight))
        northRect = rect(area.rect.xy + vec2(0, AreaHeaderHeight), vec2(area.rect.w, area.rect.h * 0.2))
        southRect = rect(area.rect.xy + vec2(0, area.rect.h * 0.8), vec2(area.rect.w, area.rect.h * 0.2))
        eastRect = rect(area.rect.xy + vec2(area.rect.w * 0.8, 0) + vec2(0, AreaHeaderHeight), vec2(area.rect.w * 0.2, area.rect.h - AreaHeaderHeight))
        westRect = rect(area.rect.xy + vec2(0, AreaHeaderHeight), vec2(area.rect.w * 0.2, area.rect.h - AreaHeaderHeight))

      if mousePos.overlaps(headerRect):
        areaScan = Header
        resRect = headerRect
      elif mousePos.overlaps(northRect):
        areaScan = North
        resRect = northRect
      elif mousePos.overlaps(southRect):
        areaScan = South
        resRect = southRect
      elif mousePos.overlaps(eastRect):
        areaScan = East
        resRect = eastRect
      elif mousePos.overlaps(westRect):
        areaScan = West
        resRect = westRect
      elif mousePos.overlaps(bodyRect):
        areaScan = Body
        resRect = bodyRect

      targetArea = area

  visit(rootArea)
  return (targetArea, areaScan, resRect)

# =============================================================================
# Panel Content Rendering (with scrollable frames)
# =============================================================================

proc formatValue(v: Value, indent: int = 0): string =
  let pad = "  ".repeat(indent)

  if v.isNil:
    return pad & "nil"

  case v.kind
  of vkNil:
    pad & "nil"
  of vkBool:
    pad & $v.boolVal
  of vkInt:
    pad & $v.intVal
  of vkFloat:
    pad & $v.floatVal
  of vkString:
    pad & "\"" & v.strVal & "\""
  of vkArray:
    if v.arrayVal.len == 0:
      pad & "[]"
    else:
      var parts: seq[string] = @[]
      for elem in v.arrayVal:
        parts.add(formatValue(elem, 0))
      pad & "[" & parts.join(", ") & "]"
  of vkSet:
    if v.setVal.len == 0:
      pad & "{}"
    else:
      var parts: seq[string] = @[]
      for elem in v.setVal:
        parts.add(formatValue(elem, 0))
      pad & "{" & parts.join(", ") & "}"
  of vkTable:
    if v.tableVal.len == 0:
      pad & "{:}"
    else:
      var parts: seq[string] = @[]
      for k, val in v.tableVal:
        parts.add("\"" & k & "\": " & formatValue(val, 0))
      pad & "{" & parts.join(", ") & "}"
  of vkObject:
    var parts: seq[string] = @[]
    for k, val in v.objFields:
      parts.add(k & ": " & formatValue(val, 0))
    pad & v.objType & "(" & parts.join(", ") & ")"
  of vkProc:
    pad & "<proc " & v.procName & ">"
  of vkNativeProc:
    pad & "<native " & v.nativeName & ">"
  of vkType:
    pad & "<type " & v.typeNameVal & ">"
  of vkRange:
    if v.rangeInclusive:
      pad & $v.rangeStart & ".." & $v.rangeEnd
    else:
      pad & $v.rangeStart & "..<" & $v.rangeEnd

proc drawSourceCodeContent(frameId: string) =
  ## Draw source code content - call inside a frame template.
  if debugState == nil:
    text "(no script loaded)"
    return

  let contentWidth = sk.size.x - 16
  # Get actual font line height
  let font = sk.atlas.fonts["Code"]
  let actualLineHeight = font.lineHeight
  
  # Track the target line position for scroll-to-line
  var targetLineTop: float32 = 0
  var targetLineBottom: float32 = 0
  var foundTargetLine = false

  for i, line in debugState.sourceLines:
    let lineNum = i + 1
    let isCurrentLine = debugState.vm != nil and lineNum == debugState.vm.currentLine and not debugState.vm.isFinished
    let hasBreakpoint = debugState.vm != nil and debugState.vm.hasBreakpoint(lineNum)

    # The current position (sk.at) is already scroll-adjusted by the frame
    let lineY = sk.at.y
    let lineX = sk.at.x
    
    # Track target line position (in scrolled coordinates relative to frame)
    if scrollToLineRequest > 0 and lineNum == scrollToLineRequest:
      # Store position relative to frame origin, accounting for current scroll
      let currentScroll = if frameId in frameStates: frameStates[frameId].scrollPos.y else: 0.0
      targetLineTop = lineY - sk.pos.y + currentScroll
      targetLineBottom = targetLineTop + actualLineHeight
      foundTargetLine = true

    # Define clickable area for breakpoint toggle (line number gutter)
    let gutterRect = rect(lineX, lineY, LineNumberWidth, actualLineHeight)

    # Handle breakpoint click - mouseInsideClip accounts for scroll & clipping
    if mouseInsideClip(gutterRect) and window.buttonPressed[MouseLeft]:
      toggleBreakpoint(lineNum)

    # Draw breakpoint line background
    if hasBreakpoint and not isCurrentLine:
      sk.drawRect(
        vec2(lineX, lineY),
        vec2(contentWidth, actualLineHeight),
        BreakpointLineColor
      )

    # Draw current line highlight (on top of breakpoint background)
    if isCurrentLine:
      sk.drawRect(
        vec2(lineX, lineY),
        vec2(contentWidth, actualLineHeight),
        CurrentLineColor
      )

    # Draw breakpoint indicator (red dot in line number area)
    if hasBreakpoint:
      let dotX = lineX + 6
      let dotY = lineY + (actualLineHeight - 10) / 2
      sk.drawRect(vec2(dotX, dotY), vec2(10, 10), BreakpointColor)

    # Draw line number
    let lineNumStr = align($lineNum, 4)
    discard sk.drawText("Code", lineNumStr, vec2(lineX + 20, lineY), LineNumberColor)

    # Draw code
    let codeX = lineX + LineNumberWidth
    discard sk.drawText("Code", line, vec2(codeX, lineY), CodeColor)

    sk.advance(vec2(contentWidth, actualLineHeight))
  
  # Apply scroll-to-line after drawing all content
  if scrollToLineRequest > 0 and foundTargetLine and frameId in frameStates:
    let currentScroll = frameStates[frameId].scrollPos.y
    let visibleHeight = sk.size.y
    
    # Check if line is within the comfortable visible area (with margin)
    let viewTop = currentScroll + ScrollMargin
    let viewBottom = currentScroll + visibleHeight - ScrollMargin
    
    if targetLineTop < viewTop:
      # Line is above visible area - scroll up to show it with margin at top
      frameStates[frameId].scrollPos.y = max(0.0, targetLineTop - ScrollMargin)
    elif targetLineBottom > viewBottom:
      # Line is below visible area - scroll down to show it with margin at bottom
      frameStates[frameId].scrollPos.y = max(0.0, targetLineBottom - visibleHeight + ScrollMargin)
    
    scrollToLineRequest = 0

proc drawButton(label: string, x, y, w, h: float32, enabled: bool = true): bool =
  ## Draw a button and return true if clicked.
  let btnRect = rect(x, y, w, h)
  let mousePos = window.mousePos.vec2
  let isHovered = mousePos.overlaps(btnRect) and enabled
  let isPressed = isHovered and window.buttonPressed[MouseLeft]

  let bgColor = if not enabled:
    rgbx(60, 60, 70, 255)
  elif isHovered:
    ButtonHoverColor
  else:
    ButtonColor

  sk.drawRect(vec2(x, y), vec2(w, h), bgColor)

  let textSize = sk.getTextSize("Default", label)
  let textX = x + (w - textSize.x) / 2
  let textY = y + (h - textSize.y) / 2

  let textColor = if enabled: rgbx(255, 255, 255, 255) else: rgbx(100, 100, 100, 255)
  discard sk.drawText("Default", label, vec2(textX, textY), textColor)

  return isPressed and enabled

proc drawControlsContent() =
  ## Draw debug controls panel content.
  if debugState == nil:
    text "(no script loaded)"
    return

  let baseX = sk.at.x
  let btnW = 70.0'f32
  let btnH = 26.0'f32
  let spacing = 6.0'f32
  
  # Can run if VM exists, not finished, and no error
  let canRun = debugState.vm != nil and not debugState.vm.isFinished and not debugState.hasError

  # Row 1: Execution controls
  var x = baseX
  var y = sk.at.y

  if drawButton("Continue", x, y, btnW, btnH, canRun):
    continueDebugger()
  x += btnW + spacing

  if drawButton("Step", x, y, 50, btnH, canRun):
    stepDebugger()
  x += 50 + spacing

  if drawButton("Into", x, y, 45, btnH, canRun):
    stepIntoDebugger()
  x += 45 + spacing

  if drawButton("Out", x, y, 40, btnH, canRun):
    stepOutDebugger()
  x += 40 + spacing

  if drawButton("Restart", x, y, 60, btnH):
    initDebugger(debugState.scriptPath)

  sk.advance(vec2(sk.size.x - 32, btnH + spacing))

proc drawStackTraceContent() =
  ## Draw stack trace content - call inside a frame template.
  if debugState == nil:
    text "(no script loaded)"
    return
  
  if debugState.vm == nil:
    # No VM means syntax error or other issue - show nothing
    return

  # Get actual font line height
  let font = sk.atlas.fonts["Code"]
  let actualLineHeight = font.lineHeight

  # Build call stack from VM's execution frames
  var callStack: seq[string] = @["<main>"]
  for frame in debugState.vm.frames:
    if frame.kind == fkFunction and frame.funcName.len > 0:
      callStack.add(frame.funcName)

  for i, frm in callStack:
    let indent = "  ".repeat(i)
    discard sk.drawText("Code", indent & frm, sk.at, CodeColor)
    sk.advance(vec2(200, actualLineHeight))

  if debugState.vm.isFinished:
    sk.advance(vec2(0, 8))
    discard sk.drawText("Default", "Execution complete.", sk.at, SuccessColor)
    sk.advance(vec2(150, 20))

proc drawOutputContent(frameId: string) =
  ## Draw output content - call inside a frame template.
  if debugState == nil:
    text "(no script loaded)"
    return

  # Get actual font line height
  let font = sk.atlas.fonts["Code"]
  let actualLineHeight = font.lineHeight

  if debugState.outputLines.len == 0:
    discard sk.drawText("Code", "(no output)", sk.at, DimTextColor)
    sk.advance(vec2(100, actualLineHeight))
  else:
    for line in debugState.outputLines:
      let color = if line.isError: BreakpointColor else: CodeColor  # Red for errors
      discard sk.drawText("Code", line.text, sk.at, color)
      sk.advance(vec2(sk.size.x - 32, actualLineHeight))
  
  # Scroll to bottom if requested - do this AFTER drawing content.
  # Use sk.stretchAt.y which tracks the maximum Y position content was drawn to.
  if scrollOutputToBottomRequest and frameId in frameStates:
    # sk.stretchAt.y is in scrolled coordinates, so we need to add back current scroll
    # to get the actual content extent. sk.pos.y is the frame origin.
    let currentScroll = frameStates[frameId].scrollPos.y
    let contentBottom = sk.stretchAt.y + currentScroll - sk.pos.y + 16  # +16 for padding
    let visibleHeight = sk.size.y
    
    # Set scroll so the bottom of content aligns with bottom of visible area
    let maxScroll = max(0.0, contentBottom - visibleHeight)
    
    frameStates[frameId].scrollPos.y = maxScroll
    scrollOutputToBottomRequest = false

proc drawVariablesContent() =
  ## Draw variables content - call inside a frame template.
  if debugState == nil:
    text "(no script loaded)"
    return
  
  if debugState.vm == nil:
    # No VM means syntax error - show nothing
    return

  # Get actual font line height
  let font = sk.atlas.fonts["Code"]
  let actualLineHeight = font.lineHeight

  var hasVars = false
  var scope = debugState.vm.currentScope

  while scope != nil:
    for name, value in scope.vars:
      # Skip built-in functions and types
      if value.kind == vkNativeProc or value.kind == vkType:
        continue

      hasVars = true
      let valueStr = formatValue(value, 0)
      let displayStr = name & " = " & valueStr
      discard sk.drawText("Code", displayStr, sk.at, CodeColor)
      sk.advance(vec2(sk.size.x - 32, actualLineHeight))

    scope = scope.parent

  if not hasVars:
    discard sk.drawText("Code", "(no variables)", sk.at, DimTextColor)
    sk.advance(vec2(100, actualLineHeight))

proc drawPanelContent(panel: Panel, contentRect: Rect) =
  let frameId = "panel:" & panel.name & ":" & $cast[uint](panel)
  
  frame(frameId, contentRect.xy, contentRect.wh):
    case panel.kind
    of pkSourceCode:
      drawSourceCodeContent(frameId)
    of pkStackTrace:
      drawStackTraceContent()
    of pkOutput:
      drawOutputContent(frameId)
    of pkVariables:
      drawVariablesContent()
    of pkControls:
      drawControlsContent()

# =============================================================================
# Panel Drawing
# =============================================================================

proc drawAreaRecursive(area: Area, r: Rect) =
  area.rect = r.snapToPixels()

  if area.areas.len > 0:
    let m = AreaMargin / 2
    if area.layout == Horizontal:
      let splitPos = r.h * area.split
      let splitRect = rect(r.x, r.y + splitPos - 2, r.w, 4)

      if dragArea == nil and window.mousePos.vec2.overlaps(splitRect):
        sk.cursor = Cursor(kind: ResizeUpDownCursor)
        if window.buttonPressed[MouseLeft]:
          dragArea = area

      let r1 = rect(r.x, r.y, r.w, splitPos - m)
      let r2 = rect(r.x, r.y + splitPos + m, r.w, r.h - splitPos - m)
      drawAreaRecursive(area.areas[0], r1)
      drawAreaRecursive(area.areas[1], r2)

    else:
      let splitPos = r.w * area.split
      let splitRect = rect(r.x + splitPos - 2, r.y, 4, r.h)

      if dragArea == nil and window.mousePos.vec2.overlaps(splitRect):
        sk.cursor = Cursor(kind: ResizeLeftRightCursor)
        if window.buttonPressed[MouseLeft]:
          dragArea = area

      let r1 = rect(r.x, r.y, splitPos - m, r.h)
      let r2 = rect(r.x + splitPos + m, r.y, r.w - splitPos - m, r.h)
      drawAreaRecursive(area.areas[0], r1)
      drawAreaRecursive(area.areas[1], r2)

  elif area.panels.len > 0:
    if area.selectedPanelNum > area.panels.len - 1:
      area.selectedPanelNum = area.panels.len - 1

    # Draw Header
    let headerRect = rect(r.x, r.y, r.w, AreaHeaderHeight)
    sk.draw9Patch("panel.header.9patch", 3, headerRect.xy, headerRect.wh)

    # Draw Tabs
    var x = r.x + 4
    sk.pushClipRect(rect(r.x, r.y, r.w - 2, AreaHeaderHeight))

    for i, panel in area.panels:
      let textSize = sk.getTextSize("Default", panel.name)
      let tabW = textSize.x + 16
      let tabRect = rect(x, r.y + 4, tabW, AreaHeaderHeight - 4)

      let isSelected = i == area.selectedPanelNum
      let isHovered = window.mousePos.vec2.overlaps(tabRect)

      if isHovered:
        if window.buttonPressed[MouseLeft]:
          area.selectedPanelNum = i
          maybeDragStartPos = window.mousePos.vec2
          maybeDragPanel = panel
        elif window.buttonDown[MouseLeft] and dragPanel == panel:
          discard

      if window.buttonDown[MouseLeft]:
        if maybeDragPanel != nil and (maybeDragStartPos - window.mousePos.vec2).length() > 10:
          dragPanel = maybeDragPanel
          maybeDragStartPos = vec2(0, 0)
          maybeDragPanel = nil
      else:
        maybeDragStartPos = vec2(0, 0)
        maybeDragPanel = nil

      if isSelected:
        sk.draw9Patch("panel.tab.selected.9patch", 3, tabRect.xy, tabRect.wh, rgbx(255, 255, 255, 255))
      elif isHovered:
        sk.draw9Patch("panel.tab.hover.9patch", 3, tabRect.xy, tabRect.wh, rgbx(255, 255, 255, 255))
      else:
        sk.draw9Patch("panel.tab.9patch", 3, tabRect.xy, tabRect.wh)

      discard sk.drawText("Default", panel.name, vec2(x + 8, r.y + 4 + 4), rgbx(255, 255, 255, 255))
      x += tabW + 2

    sk.popClipRect()

    # Draw Content (scrollable frame)
    let contentRect = rect(r.x + 2, r.y + AreaHeaderHeight + 2, r.w - 4, r.h - AreaHeaderHeight - 4)
    let activePanel = area.panels[area.selectedPanelNum]
    drawPanelContent(activePanel, contentRect)

# =============================================================================
# Initialization
# =============================================================================

proc initRootArea() =
  rootArea = Area()

  # Main split: Left (code + output) | Right (controls + variables + stack)
  rootArea.split(Vertical)
  rootArea.split = 0.68

  # Left column: Source Code (top 75%) + Output (bottom 25%)
  rootArea.areas[0].split(Horizontal)
  rootArea.areas[0].split = 0.75
  gSourceCodePanel = rootArea.areas[0].areas[0].addPanel("Source Code", pkSourceCode)
  gOutputPanel = rootArea.areas[0].areas[1].addPanel("Output", pkOutput)

  # Right column: Controls (top) + Variables (middle) + Stack Trace (bottom)
  rootArea.areas[1].split(Horizontal)
  rootArea.areas[1].split = 0.12
  discard rootArea.areas[1].areas[0].addPanel("Controls", pkControls)

  # Variables + Stack below Controls
  rootArea.areas[1].areas[1].split(Horizontal)
  rootArea.areas[1].areas[1].split = 0.65
  discard rootArea.areas[1].areas[1].areas[0].addPanel("Variables", pkVariables)
  discard rootArea.areas[1].areas[1].areas[1].addPanel("Stack Trace", pkStackTrace)

# =============================================================================
# Main
# =============================================================================

proc main() =
  # Parse command-line arguments
  if paramCount() < 1:
    echo "Usage: visualizer <script.nimmy>"
    echo ""
    echo "A visual step-by-step debugger for Nimmy scripts."
    echo "Press Space or Enter to step through the code."
    quit(0)

  let scriptPath = paramStr(1)

  initRootArea()
  initDebugger(scriptPath)

  # Main Loop
  window.onFrame = proc() =
    sk.beginUI(window, window.size)

    # Background
    sk.drawRect(vec2(0, 0), window.size.vec2, BackgroundColor)

    # Reset cursor
    sk.cursor = Cursor(kind: ArrowCursor)

    # Handle keyboard shortcuts
    if window.buttonPressed[KeySpace] or window.buttonPressed[KeyEnter]:
      stepDebugger()

    if window.buttonPressed[KeyC]:
      continueDebugger()

    if window.buttonPressed[KeyR]:
      initDebugger(scriptPath)

    if window.buttonPressed[KeyI]:
      stepIntoDebugger()

    if window.buttonPressed[KeyO]:
      stepOutDebugger()

    # Update Dragging Split
    if dragArea != nil:
      if not window.buttonDown[MouseLeft]:
        dragArea = nil
      else:
        if dragArea.layout == Horizontal:
          sk.cursor = Cursor(kind: ResizeUpDownCursor)
          dragArea.split = (window.mousePos.vec2.y - dragArea.rect.y) / dragArea.rect.h
        else:
          sk.cursor = Cursor(kind: ResizeLeftRightCursor)
          dragArea.split = (window.mousePos.vec2.x - dragArea.rect.x) / dragArea.rect.w
        dragArea.split = clamp(dragArea.split, 0.1, 0.9)

    # Update Dragging Panel
    showDropHighlight = false
    if dragPanel != nil:
      if not window.buttonDown[MouseLeft]:
        let (targetArea, areaScan, _) = rootArea.scan()
        if targetArea != nil:
          case areaScan:
            of Header:
              let (idx, _) = targetArea.getTabInsertInfo(window.mousePos.vec2)
              targetArea.insertPanel(dragPanel, idx)
            of Body:
              targetArea.movePanel(dragPanel)
            of North:
              targetArea.split(Horizontal)
              targetArea.areas[0].movePanel(dragPanel)
              targetArea.areas[1].movePanels(targetArea.panels)
            of South:
              targetArea.split(Horizontal)
              targetArea.areas[1].movePanel(dragPanel)
              targetArea.areas[0].movePanels(targetArea.panels)
            of East:
              targetArea.split(Vertical)
              targetArea.areas[1].movePanel(dragPanel)
              targetArea.areas[0].movePanels(targetArea.panels)
            of West:
              targetArea.split(Vertical)
              targetArea.areas[0].movePanel(dragPanel)
              targetArea.areas[1].movePanels(targetArea.panels)

          rootArea.removeBlankAreas()
        dragPanel = nil
      else:
        let (targetArea, areaScan, rect) = rootArea.scan()
        dropHighlight = rect
        showDropHighlight = true

        if targetArea != nil and areaScan == Header:
          let (_, highlightRect) = targetArea.getTabInsertInfo(window.mousePos.vec2)
          dropHighlight = highlightRect

    # Draw Areas (reserve space for status bar)
    let statusBarHeight = 28.0'f32
    drawAreaRecursive(rootArea, rect(0, 0, window.size.x.float32, window.size.y.float32 - statusBarHeight))

    # Draw Drop Highlight
    if showDropHighlight and dragPanel != nil:
      sk.drawRect(dropHighlight.xy, dropHighlight.wh, rgbx(255, 255, 0, 100))

      let label = dragPanel.name
      let textSize = sk.getTextSize("Default", label)
      let size = textSize + vec2(16, 8)
      sk.draw9Patch("tooltip.9patch", 4, window.mousePos.vec2 + vec2(10, 10), size, rgbx(255, 255, 255, 200))
      discard sk.drawText("Default", label, window.mousePos.vec2 + vec2(18, 14), rgbx(255, 255, 255, 255))

    # Draw status bar
    let statusY = window.size.y.float32 - statusBarHeight
    sk.drawRect(vec2(0, statusY), vec2(window.size.x.float32, statusBarHeight), rgbx(40, 42, 54, 255))

    let statusText = if debugState != nil:
      if debugState.hasError:
        "Error | Press R to restart"
      elif debugState.vm == nil:
        "Failed to load | Press R to restart"
      elif debugState.vm.isFinished:
        "Finished | Press R to restart"
      else:
        fmt"Line {debugState.vm.currentLine} | Space=Step, C=Continue, R=Restart"
    else:
      "No script loaded"

    discard sk.drawText("Default", statusText, vec2(10, statusY + 6), rgbx(200, 200, 200, 255))

    # Show script path on the right
    if debugState != nil:
      let pathText = debugState.scriptPath
      let pathSize = sk.getTextSize("Default", pathText)
      discard sk.drawText("Default", pathText, vec2(window.size.x.float32 - pathSize.x - 10, statusY + 6), rgbx(150, 150, 150, 255))

    sk.endUi()
    window.swapBuffers()

    if window.cursor.kind != sk.cursor.kind:
      window.cursor = sk.cursor

  while not window.closeRequested:
    pollEvents()

main()
