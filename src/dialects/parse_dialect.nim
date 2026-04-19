import std/[strutils, tables]
import ../core/[types, equality]
import ../eval/[dialect, evaluator]

## Parse dialect — PEG-style parsing with backtracking.
## Registered as a native function with arity 2: `parse input rules`
##
## Two modes:
##   - String mode: input is a string!, elements are characters
##   - Block mode: input is a block!, elements are values
##
## Returns a context! with `ok` field (logic!) plus any set-word captures
## and collect results.

type
  ParseMode = enum
    pmString
    pmBlock

  CollectFrame = ref object
    values: seq[KtgValue]

  BacktrackPoint = object
    ruleIdx: int             # index into the alt sequence where some/any was
    positions: seq[int]      # saved input positions at each match count
    captureSnapshots: seq[OrderedTable[string, KtgValue]]
    currentCount: int        # current match count to try next
    minCount: int            # 1 for some, 0 for any
    rposAfterRule: int       # rpos after skipping the some/any sub-rule

  ParseState = ref object
    mode: ParseMode
    # string mode
    str: string
    # block mode
    blk: seq[KtgValue]
    # shared
    pos: int
    captures: OrderedTable[string, KtgValue]
    collectStack: seq[CollectFrame]
    eval: Evaluator
    breakFlag: bool
    backtrackStack: seq[BacktrackPoint]

# --- Helpers ---

proc inputLen(s: ParseState): int =
  case s.mode
  of pmString: s.str.len
  of pmBlock: s.blk.len

proc atEnd(s: ParseState): bool =
  s.pos >= s.inputLen

proc isCharClass(name: string): bool =
  name in ["alpha", "digit", "alnum", "space", "upper", "lower", "newline"]

proc matchCharClass(name: string, ch: char): bool =
  case name
  of "alpha": ch in {'a'..'z', 'A'..'Z'}
  of "digit": ch in {'0'..'9'}
  of "alnum": ch in {'a'..'z', 'A'..'Z', '0'..'9'}
  of "space": ch in {' ', '\t', '\n', '\r'}
  of "upper": ch in {'A'..'Z'}
  of "lower": ch in {'a'..'z'}
  of "newline": ch == '\n'
  else: false

proc typeNameToKind(name: string): ValueKind =
  case name
  of "integer!": vkInteger
  of "float!": vkFloat
  of "string!": vkString
  of "logic!": vkLogic
  of "none!": vkNone
  of "money!": vkMoney
  of "pair!": vkPair
  of "tuple!": vkTuple
  of "date!": vkDate
  of "time!": vkTime
  of "file!": vkFile
  of "url!": vkUrl
  of "email!": vkEmail
  of "block!": vkBlock
  of "paren!": vkParen
  of "map!": vkMap
  of "set!": vkSet
  of "context!": vkContext
  of "object!": vkObject
  of "function!": vkFunction
  of "native!": vkNative
  of "word!": vkWord
  of "type!": vkType
  else: vkNone  # fallback

# --- Forward declarations ---

proc parseRule(s: ParseState, rules: seq[KtgValue], rpos: var int): bool
proc parseSequence(s: ParseState, rules: seq[KtgValue]): bool

proc skipRuleTokens(rules: seq[KtgValue], rpos: var int) =
  ## Advance rpos past one rule element purely syntactically, no execution.
  if rpos >= rules.len:
    return
  let rule = rules[rpos]
  rpos += 1

  if rule.kind == vkWord and rule.wordKind == wkWord:
    case rule.wordName
    of "some", "any", "opt", "not", "ahead", "to", "thru", "keep", "into":
      # These bind to the next single rule
      skipRuleTokens(rules, rpos)
    of "collect":
      # collect consumes the next block
      if rpos < rules.len and rules[rpos].kind == vkBlock:
        rpos += 1
    of "quote":
      # quote consumes the next token
      if rpos < rules.len:
        rpos += 1
    else:
      discard  # skip, end, alpha, digit, etc. are single tokens
  elif rule.kind == vkWord and rule.wordKind == wkSetWord:
    # set-word: consumes the next rule
    skipRuleTokens(rules, rpos)
  elif rule.kind == vkInteger:
    # N [M] rule: integer [integer] followed by a rule
    if rpos < rules.len and rules[rpos].kind == vkInteger:
      rpos += 1  # skip M
    if rpos < rules.len:
      skipRuleTokens(rules, rpos)
  # All other tokens (string, block, type, lit-word, etc.) are single tokens

# --- Core rule matching ---

proc parseSingleRule(s: ParseState, rules: seq[KtgValue], rpos: var int): bool =
  ## Parse a single rule element at rpos. Advances rpos past the consumed rule tokens.
  ## Returns true if the rule matched. Manages input position (s.pos) with backtracking.
  if rpos >= rules.len:
    return true  # empty rule always succeeds

  let rule = rules[rpos]
  rpos += 1

  # --- String literal match ---
  if rule.kind == vkString:
    if s.mode == pmString:
      let lit = rule.strVal
      if s.pos + lit.len <= s.str.len and s.str[s.pos ..< s.pos + lit.len] == lit:
        s.pos += lit.len
        return true
      return false
    else:
      # Block mode: match string value
      if not s.atEnd and s.blk[s.pos].kind == vkString and s.blk[s.pos].strVal == rule.strVal:
        s.pos += 1
        return true
      return false

  # --- Integer literal (could be N-times or N M repetition) ---
  if rule.kind == vkInteger:
    let n = int(rule.intVal)
    # Check for N M rule (between N and M repetitions)
    if rpos < rules.len and rules[rpos].kind == vkInteger:
      let m = int(rules[rpos].intVal)
      rpos += 1  # consume M
      if rpos < rules.len:
        let savedPos = s.pos
        let ruleStart = rpos
        # Try up to M matches, need at least N
        var count = 0
        var positions: seq[int] = @[s.pos]  # position after 0 matches
        var finalRpos = rpos
        for i in 0 ..< m:
          var subRpos = ruleStart
          if not s.parseRule(rules, subRpos):
            break
          count += 1
          finalRpos = subRpos
          positions.add(s.pos)
        if count < n:
          s.pos = savedPos
          skipRuleTokens(rules, rpos)
          return false
        rpos = finalRpos
        return true
      return false
    if rpos < rules.len:
      # N rule: exactly N repetitions of the next single rule
      let savedPos = s.pos
      var finalRpos = rpos
      for i in 0 ..< n:
        var subRpos = rpos
        if not s.parseRule(rules, subRpos):
          s.pos = savedPos
          return false
        finalRpos = subRpos
      rpos = finalRpos
      return true
    # Bare integer with nothing after — in block mode, match literal
    if s.mode == pmBlock:
      rpos -= 1  # un-consume the integer rule token
      if not s.atEnd and valuesEqual(s.blk[s.pos], rule):
        s.pos += 1
        rpos += 1
        return true
      rpos += 1
      return false
    return false

  # --- Block: sub-rule grouping ---
  if rule.kind == vkBlock:
    let savedPos = s.pos
    if s.parseSequence(rule.blockVals):
      return true
    s.pos = savedPos
    return false

  # --- Paren: side-effect expression (always succeeds) ---
  if rule.kind == vkParen:
    discard s.eval.evalBlock(rule.parenVals, s.eval.currentCtx)
    return true

  # --- Type in block mode ---
  if rule.kind == vkType:
    if s.mode == pmBlock:
      if not s.atEnd:
        let expected = typeNameToKind(rule.typeName)
        if s.blk[s.pos].kind == expected:
          s.pos += 1
          return true
        # Also handle word subtypes
        if expected == vkWord and s.blk[s.pos].kind == vkWord:
          s.pos += 1
          return true
      return false
    else:
      return false

  # --- Word rules ---
  if rule.kind == vkWord:
    case rule.wordKind
    of wkWord:
      let name = rule.wordName

      # Keywords
      case name
      of "skip":
        if s.atEnd: return false
        s.pos += 1
        return true

      of "end":
        return s.atEnd

      of "some":
        # One or more, greedy with backtrack point.
        let savedPos = s.pos
        var positions: seq[int] = @[savedPos]
        var capSnaps: seq[OrderedTable[string, KtgValue]] = @[s.captures]
        var count = 0
        while true:
          let beforePos = s.pos
          var subRpos = rpos
          if not s.parseRule(rules, subRpos):
            s.pos = beforePos
            break
          if s.pos == beforePos:
            break
          count += 1
          positions.add(s.pos)
          capSnaps.add(s.captures)
          if s.breakFlag:
            s.breakFlag = false
            break
        if count == 0:
          s.pos = savedPos
          s.captures = capSnaps[0]
          skipRuleTokens(rules, rpos)
          return false
        var afterRuleRpos = rpos
        skipRuleTokens(rules, afterRuleRpos)
        # Push backtrack point so sequence can retry with fewer matches
        s.backtrackStack.add(BacktrackPoint(
          ruleIdx: 0,  # not used directly
          positions: positions,
          captureSnapshots: capSnaps,
          currentCount: count - 1,  # next retry would be count-1
          minCount: 1,
          rposAfterRule: afterRuleRpos
        ))
        rpos = afterRuleRpos
        return true

      of "any":
        # Zero or more, greedy with backtrack point.
        let savedPos = s.pos
        var positions: seq[int] = @[savedPos]
        var capSnaps: seq[OrderedTable[string, KtgValue]] = @[s.captures]
        var count = 0
        while true:
          let beforePos = s.pos
          var subRpos = rpos
          if not s.parseRule(rules, subRpos):
            s.pos = beforePos
            break
          if s.pos == beforePos:
            break
          count += 1
          positions.add(s.pos)
          capSnaps.add(s.captures)
          if s.breakFlag:
            s.breakFlag = false
            break
        var afterRuleRpos = rpos
        skipRuleTokens(rules, afterRuleRpos)
        s.backtrackStack.add(BacktrackPoint(
          ruleIdx: 0,
          positions: positions,
          captureSnapshots: capSnaps,
          currentCount: count - 1,
          minCount: 0,
          rposAfterRule: afterRuleRpos
        ))
        rpos = afterRuleRpos
        return true

      of "opt":
        # Zero or one of next rule
        let beforePos = s.pos
        var subRpos = rpos
        if not s.parseRule(rules, subRpos):
          s.pos = beforePos
        skipRuleTokens(rules, rpos)
        return true  # always succeeds

      of "not":
        # Negative lookahead
        let savedPos = s.pos
        var subRpos = rpos
        let matched = s.parseRule(rules, subRpos)
        s.pos = savedPos
        skipRuleTokens(rules, rpos)
        return not matched

      of "ahead":
        # Positive lookahead
        let savedPos = s.pos
        var subRpos = rpos
        let matched = s.parseRule(rules, subRpos)
        s.pos = savedPos
        skipRuleTokens(rules, rpos)
        return matched

      of "to":
        # Scan forward to (not past) match
        let startPos = s.pos
        while not s.atEnd:
          let tryPos = s.pos
          var subRpos = rpos
          if s.parseRule(rules, subRpos):
            # Found match — restore pos to just before match
            s.pos = tryPos
            skipRuleTokens(rules, rpos)
            return true
          s.pos = tryPos + 1
        # Also try at end position (for `end` combinator)
        let tryPos = s.pos
        var subRpos2 = rpos
        if s.parseRule(rules, subRpos2):
          s.pos = tryPos
          skipRuleTokens(rules, rpos)
          return true
        s.pos = startPos
        skipRuleTokens(rules, rpos)
        return false

      of "thru":
        # Scan forward through (past) match
        let startPos = s.pos
        while not s.atEnd:
          let tryPos = s.pos
          var subRpos = rpos
          if s.parseRule(rules, subRpos):
            # Found match — pos is already past match
            skipRuleTokens(rules, rpos)
            return true
          s.pos = tryPos + 1
        s.pos = startPos
        skipRuleTokens(rules, rpos)
        return false

      of "quote":
        # Match next value literally (escape keywords)
        if rpos >= rules.len:
          return false
        let quoted = rules[rpos]
        rpos += 1
        if s.mode == pmBlock:
          if not s.atEnd and valuesEqual(s.blk[s.pos], quoted):
            s.pos += 1
            return true
          return false
        else:
          if quoted.kind == vkString:
            let lit = quoted.strVal
            if s.pos + lit.len <= s.str.len and s.str[s.pos ..< s.pos + lit.len] == lit:
              s.pos += lit.len
              return true
          return false

      of "collect":
        # collect [sub-rule]: wrap rule, keep inside appends to block
        if rpos >= rules.len or rules[rpos].kind != vkBlock:
          return false
        let subRules = rules[rpos].blockVals
        rpos += 1
        let frame = CollectFrame(values: @[])
        s.collectStack.add(frame)
        let savedPos = s.pos
        let ok = s.parseSequence(subRules)
        discard s.collectStack.pop()
        if not ok:
          s.pos = savedPos
          return false
        # The collected block is available for capture via set-word
        # We store it temporarily in a special capture key
        s.captures["__last_collect__"] = ktgBlock(frame.values)
        return true

      of "keep":
        # Inside collect: match rule and append matched value
        if s.collectStack.len == 0:
          raise KtgError(kind: "parse",
            msg: "keep used outside of collect",
            data: nil)
        let beforePos = s.pos
        var subRpos = rpos
        if not s.parseRule(rules, subRpos):
          return false
        rpos = subRpos
        let frame = s.collectStack[^1]
        # Capture what was matched
        if s.mode == pmString:
          let matched = s.str[beforePos ..< s.pos]
          frame.values.add(ktgString(matched))
        else:
          for i in beforePos ..< s.pos:
            frame.values.add(s.blk[i])
        return true

      of "into":
        # Descend into a nested block and apply sub-rules inside it.
        # Block parse mode only.
        if s.mode != pmBlock:
          raise KtgError(kind: "parse",
            msg: "into only works in block parse mode",
            data: nil)
        if s.atEnd:
          skipRuleTokens(rules, rpos)
          return false
        let current = s.blk[s.pos]
        if current.kind != vkBlock:
          skipRuleTokens(rules, rpos)
          return false
        # The next rule token must be a block of sub-rules
        if rpos >= rules.len or rules[rpos].kind != vkBlock:
          raise KtgError(kind: "parse",
            msg: "into expects a block of sub-rules",
            data: nil)
        let subRules = rules[rpos].blockVals
        rpos += 1
        # Create a new parse state for the inner block
        let innerState = ParseState(
          mode: pmBlock,
          blk: current.blockVals,
          pos: 0,
          captures: s.captures,
          collectStack: s.collectStack,
          eval: s.eval
        )
        let matched = innerState.parseSequence(subRules)
        if matched and innerState.atEnd:
          # Merge any captures back
          for name, val in innerState.captures:
            s.captures[name] = val
          s.pos += 1
          return true
        return false

      of "break":
        # Signal some/any loops to exit
        s.breakFlag = true
        return true

      of "fail":
        return false

      else:
        # Character class or value lookup
        if s.mode == pmString and isCharClass(name):
          if s.atEnd: return false
          if matchCharClass(name, s.str[s.pos]):
            s.pos += 1
            return true
          return false

        # In block mode, bare word could be looked up in context
        # For now, treat unknown words as errors
        raise KtgError(kind: "parse",
          msg: "unknown parse keyword: " & name,
          data: rule)

    of wkSetWord:
      # name: rule — capture
      let captureName = rule.wordName
      let beforePos = s.pos

      # Check if next is `collect`
      if rpos < rules.len and rules[rpos].kind == vkWord and
         rules[rpos].wordKind == wkWord and rules[rpos].wordName == "collect":
        var subRpos = rpos
        if not s.parseRule(rules, subRpos):
          return false
        rpos = subRpos
        # Grab the collected block
        if "__last_collect__" in s.captures:
          s.captures[captureName] = s.captures["__last_collect__"]
          s.captures.del("__last_collect__")
        return true

      # Regular capture: match the next rule and capture what was consumed
      var subRpos = rpos
      if not s.parseRule(rules, subRpos):
        return false
      rpos = subRpos

      # Capture the matched portion
      if s.mode == pmString:
        let matched = s.str[beforePos ..< s.pos]
        s.captures[captureName] = ktgString(matched)
      else:
        # Block mode: capture the single value (or sequence)
        let count = s.pos - beforePos
        if count == 1:
          s.captures[captureName] = s.blk[beforePos]
        elif count > 1:
          var vals: seq[KtgValue] = @[]
          for i in beforePos ..< s.pos:
            vals.add(s.blk[i])
          s.captures[captureName] = ktgBlock(vals)
        else:
          s.captures[captureName] = ktgNone()
      return true

    of wkLitWord:
      # 'word — match literal word in block mode
      if s.mode == pmBlock:
        if not s.atEnd and s.blk[s.pos].kind == vkWord and
           s.blk[s.pos].wordName.toLowerAscii == rule.wordName.toLowerAscii:
          s.pos += 1
          return true
        return false
      return false

    else:
      return false

  # --- Literal values (integer, float, logic, etc.) for block mode ---
  if s.mode == pmBlock and rule.kind in {vkInteger, vkFloat, vkLogic, vkNone,
     vkMoney, vkPair, vkTuple, vkDate, vkTime, vkFile, vkUrl, vkEmail}:
    if not s.atEnd and valuesEqual(s.blk[s.pos], rule):
      s.pos += 1
      return true
    return false

  return false


proc parseRule(s: ParseState, rules: seq[KtgValue], rpos: var int): bool =
  ## Parse one rule (which may be a compound rule like `some [...]`).
  ## This is the entry point that parseSingleRule delegates to for sub-rules.
  parseSingleRule(s, rules, rpos)


proc parseSequence(s: ParseState, rules: seq[KtgValue]): bool =
  ## Parse a sequence of rules with `|` as lowest-precedence alternative.
  ## `a b | c d` means try `a b`, if that fails try `c d`.

  # Split on `|` — find alternatives
  var alternatives: seq[seq[KtgValue]] = @[]
  var current: seq[KtgValue] = @[]

  for r in rules:
    if r.kind == vkWord and r.wordKind == wkWord and r.wordName == "|":
      alternatives.add(current)
      current = @[]
    else:
      current.add(r)
  alternatives.add(current)

  let savedPos = s.pos

  for alt in alternatives:
    s.pos = savedPos
    s.captures = s.captures  # preserve captures across alt attempts
    let btStackBase = s.backtrackStack.len  # mark backtrack stack level
    var rpos = 0
    var ok = true
    while rpos < alt.len:
      if not s.parseRule(alt, rpos):
        # Try backtracking: pop the most recent backtrack point and retry
        var retried = false
        while s.backtrackStack.len > btStackBase:
          var bt = s.backtrackStack.pop()
          if bt.currentCount >= bt.minCount:
            # Restore to fewer matches
            s.pos = bt.positions[bt.currentCount]
            s.captures = bt.captureSnapshots[bt.currentCount]
            rpos = bt.rposAfterRule
            # Push updated backtrack point for further retries
            if bt.currentCount - 1 >= bt.minCount:
              bt.currentCount -= 1
              s.backtrackStack.add(bt)
            retried = true
            break
        if not retried:
          ok = false
          break
    # Clean up backtrack points from this alt
    while s.backtrackStack.len > btStackBase:
      discard s.backtrackStack.pop()
    if ok:
      return true

  s.pos = savedPos
  return false


# --- Public API ---

proc executeParse*(eval: Evaluator, input: KtgValue, rules: KtgValue): KtgValue =
  ## Execute the parse dialect on input with rules. Called by @parse.
  if rules.kind != vkBlock:
    raise KtgError(kind: "type",
      msg: "@parse expects a block of rules as second argument",
      data: rules)

  let state = ParseState(
    captures: initOrderedTable[string, KtgValue](),
    collectStack: @[],
    eval: eval
  )

  case input.kind
  of vkString:
    state.mode = pmString
    state.str = input.strVal
    state.pos = 0
  of vkBlock:
    state.mode = pmBlock
    state.blk = input.blockVals
    state.pos = 0
  else:
    raise KtgError(kind: "type",
      msg: "@parse expects string! or block! as input, got " & typeName(input),
      data: input)

  let matched = state.parseSequence(rules.blockVals)
  let ok = matched and state.atEnd

  let resultCtx = newContext()
  resultCtx.set("ok", ktgLogic(ok))
  for name, val in state.captures:
    if name != "__last_collect__":
      resultCtx.set(name, val)
  KtgValue(kind: vkContext, ctx: resultCtx, line: 0)

proc registerParse*(eval: Evaluator) =
  ## Register the @parse implementation on the evaluator.
  eval.parseFn = executeParse
