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
  StepMode = enum
    smPaused       ## Waiting for user input
    smStep         ## Execute one statement then pause
    smStepInto     ## Step into function calls
    smStepOut      ## Run until we exit current call depth
    smContinue     ## Run until breakpoint or end

  DebuggerState = ref object
    scriptPath: string
    source: string
    sourceLines: seq[string]
    ast: Node
    vm: VM
    currentLine: int
    running: bool
    finished: bool
    outputLines: seq[string]
    callStack: seq[string]
    breakpoints: HashSet[int]   ## Line numbers with breakpoints
    stepMode: StepMode
    callDepth: int              ## Current call stack depth
    targetCallDepth: int        ## For step out - target depth to stop at

var debugState: DebuggerState

proc initDebugger(scriptPath: string) =
  # Preserve breakpoints across restarts
  var oldBreakpoints: HashSet[int]
  if debugState != nil:
    oldBreakpoints = debugState.breakpoints

  debugState = DebuggerState(
    scriptPath: scriptPath,
    currentLine: 0,
    running: false,
    finished: false,
    outputLines: @[],
    callStack: @["<main>"],
    breakpoints: oldBreakpoints,
    stepMode: smPaused,
    callDepth: 1,
    targetCallDepth: 0
  )

  if not fileExists(scriptPath):
    debugState.source = "# Error: File not found: " & scriptPath
    debugState.sourceLines = @[debugState.source]
    debugState.finished = true
    return

  debugState.source = readFile(scriptPath)
  debugState.sourceLines = debugState.source.splitLines()
  debugState.ast = parse(debugState.source)
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

  # Set up VM hooks for debugging
  debugState.vm.onStatement = proc(line, col: int): bool =
    debugState.currentLine = line
    
    # Capture any new output
    if debugState.vm.output.len > debugState.outputLines.len:
      for i in debugState.outputLines.len ..< debugState.vm.output.len:
        debugState.outputLines.add(debugState.vm.output[i])
    
    case debugState.stepMode
    of smPaused:
      # Already paused, don't continue
      return false
    of smStep:
      # Single step - pause after this statement
      debugState.stepMode = smPaused
      return false
    of smStepInto:
      # Step into - pause at every statement
      debugState.stepMode = smPaused
      return false
    of smStepOut:
      # Step out - continue until call depth decreases
      if debugState.callDepth <= debugState.targetCallDepth:
        debugState.stepMode = smPaused
        return false
      return true  # Keep running
    of smContinue:
      # Check for breakpoint
      if line in debugState.breakpoints:
        debugState.stepMode = smPaused
        return false
      return true  # Keep running
  
  debugState.vm.onEnterFunction = proc(name: string) =
    debugState.callStack.add(name)
    debugState.callDepth = debugState.callStack.len
  
  debugState.vm.onExitFunction = proc(name: string) =
    if debugState.callStack.len > 1:
      discard debugState.callStack.pop()
    debugState.callDepth = debugState.callStack.len
  
  # Get first line from AST
  if debugState.ast.kind == nkProgram and debugState.ast.stmts.len > 0:
    debugState.currentLine = debugState.ast.stmts[0].line
    debugState.running = true

proc toggleBreakpoint(line: int) =
  if debugState == nil:
    return
  if line in debugState.breakpoints:
    debugState.breakpoints.excl(line)
  else:
    debugState.breakpoints.incl(line)

proc runExecution() =
  ## Run the VM until it pauses or finishes
  if debugState == nil or debugState.finished:
    return
  
  try:
    discard debugState.vm.eval(debugState.ast)
    
    # Capture final output
    if debugState.vm.output.len > debugState.outputLines.len:
      for i in debugState.outputLines.len ..< debugState.vm.output.len:
        debugState.outputLines.add(debugState.vm.output[i])
    
    # Check if we truly finished or just paused
    if debugState.stepMode != smPaused:
      debugState.finished = true
  except NimmyError as e:
    debugState.outputLines.add("Error: " & e.msg)
    debugState.finished = true

proc stepDebugger() =
  ## Single step - execute one statement
  if debugState == nil or debugState.finished:
    return
  debugState.stepMode = smStep
  runExecution()

proc stepIntoDebugger() =
  ## Step into - same as step but will stop inside functions
  if debugState == nil or debugState.finished:
    return
  debugState.stepMode = smStepInto
  runExecution()

proc stepOutDebugger() =
  ## Step out - run until we exit the current function
  if debugState == nil or debugState.finished:
    return
  debugState.stepMode = smStepOut
  debugState.targetCallDepth = debugState.callDepth - 1
  if debugState.targetCallDepth < 1:
    debugState.targetCallDepth = 1
  runExecution()

proc continueDebugger() =
  ## Continue execution until breakpoint or end
  if debugState == nil or debugState.finished:
    return
  debugState.stepMode = smContinue
  runExecution()

# =============================================================================
# Panel Constants
# =============================================================================

const
  AreaHeaderHeight = 32.0
  AreaMargin = 6.0
  LineHeight = 18.0'f32
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

proc addPanel*(area: Area, name: string, kind: PanelKind) =
  let panel = Panel(name: name, kind: kind, parentArea: area)
  area.panels.add(panel)

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

proc drawSourceCodeContent() =
  ## Draw source code content - call inside a frame template.
  if debugState == nil:
    text "(no script loaded)"
    return

  let contentWidth = sk.size.x - 16

  for i, line in debugState.sourceLines:
    let lineNum = i + 1
    let isCurrentLine = lineNum == debugState.currentLine and not debugState.finished
    let hasBreakpoint = lineNum in debugState.breakpoints

    # The current position (sk.at) is already scroll-adjusted by the frame
    let lineY = sk.at.y
    let lineX = sk.at.x

    # Define clickable area for breakpoint toggle (line number gutter)
    let gutterRect = rect(lineX, lineY, LineNumberWidth, LineHeight)

    # Handle breakpoint click - mouseInsideClip accounts for scroll & clipping
    if mouseInsideClip(gutterRect) and window.buttonPressed[MouseLeft]:
      toggleBreakpoint(lineNum)

    # Draw breakpoint line background
    if hasBreakpoint and not isCurrentLine:
      sk.drawRect(
        vec2(lineX, lineY),
        vec2(contentWidth, LineHeight),
        BreakpointLineColor
      )

    # Draw current line highlight (on top of breakpoint background)
    if isCurrentLine:
      sk.drawRect(
        vec2(lineX, lineY),
        vec2(contentWidth, LineHeight),
        CurrentLineColor
      )

    # Draw breakpoint indicator (red dot in line number area)
    if hasBreakpoint:
      let dotX = lineX + 6
      let dotY = lineY + (LineHeight - 10) / 2
      sk.drawRect(vec2(dotX, dotY), vec2(10, 10), BreakpointColor)

    # Draw line number
    let lineNumStr = align($lineNum, 4)
    discard sk.drawText("Code", lineNumStr, vec2(lineX + 20, lineY), LineNumberColor)

    # Draw code
    let codeX = lineX + LineNumberWidth
    discard sk.drawText("Code", line, vec2(codeX, lineY), CodeColor)

    sk.advance(vec2(contentWidth, LineHeight))

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
  let notFinished = not debugState.finished

  # Row 1: Execution controls
  var x = baseX
  var y = sk.at.y

  if drawButton("Continue", x, y, btnW, btnH, notFinished):
    continueDebugger()
  x += btnW + spacing

  if drawButton("Step", x, y, 50, btnH, notFinished):
    stepDebugger()
  x += 50 + spacing

  if drawButton("Into", x, y, 45, btnH, notFinished):
    stepIntoDebugger()
  x += 45 + spacing

  if drawButton("Out", x, y, 40, btnH, notFinished):
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

  for i, frm in debugState.callStack:
    let indent = "  ".repeat(i)
    discard sk.drawText("Code", indent & frm, sk.at, CodeColor)
    sk.advance(vec2(200, LineHeight))

  if debugState.finished:
    sk.advance(vec2(0, 8))
    discard sk.drawText("Default", "Execution complete.", sk.at, SuccessColor)
    sk.advance(vec2(150, 20))

proc drawOutputContent() =
  ## Draw output content - call inside a frame template.
  if debugState == nil:
    text "(no script loaded)"
    return

  if debugState.outputLines.len == 0:
    discard sk.drawText("Code", "(no output)", sk.at, DimTextColor)
    sk.advance(vec2(100, LineHeight))
  else:
    for line in debugState.outputLines:
      discard sk.drawText("Code", line, sk.at, CodeColor)
      sk.advance(vec2(sk.size.x - 32, LineHeight))

proc drawVariablesContent() =
  ## Draw variables content - call inside a frame template.
  if debugState == nil:
    text "(no script loaded)"
    return

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
      sk.advance(vec2(sk.size.x - 32, LineHeight))

    scope = scope.parent

  if not hasVars:
    discard sk.drawText("Code", "(no variables)", sk.at, DimTextColor)
    sk.advance(vec2(100, LineHeight))

proc drawPanelContent(panel: Panel, contentRect: Rect) =
  let frameId = "panel:" & panel.name & ":" & $cast[uint](panel)

  frame(frameId, contentRect.xy, contentRect.wh):
    case panel.kind
    of pkSourceCode:
      drawSourceCodeContent()
    of pkStackTrace:
      drawStackTraceContent()
    of pkOutput:
      drawOutputContent()
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
  rootArea.areas[0].areas[0].addPanel("Source Code", pkSourceCode)
  rootArea.areas[0].areas[1].addPanel("Output", pkOutput)

  # Right column: Controls (top) + Variables (middle) + Stack Trace (bottom)
  rootArea.areas[1].split(Horizontal)
  rootArea.areas[1].split = 0.12
  rootArea.areas[1].areas[0].addPanel("Controls", pkControls)

  # Variables + Stack below Controls
  rootArea.areas[1].areas[1].split(Horizontal)
  rootArea.areas[1].areas[1].split = 0.65
  rootArea.areas[1].areas[1].areas[0].addPanel("Variables", pkVariables)
  rootArea.areas[1].areas[1].areas[1].addPanel("Stack Trace", pkStackTrace)

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
      if debugState.finished:
        "Finished | Press R to restart"
      else:
        fmt"Line {debugState.currentLine} | Space=Step, C=Continue, R=Restart"
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
