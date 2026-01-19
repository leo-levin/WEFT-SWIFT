// weft-compiler.js - WEFT compiler bundled for JavaScriptCore
// This file is auto-generated for embedding in Swift via JSContext

(function(global) {
  'use strict';

  // ========== Console Shim ==========
  if (typeof console === 'undefined') {
    global.console = {
      log: function() {},
      warn: function() {},
      error: function() {},
      info: function() {}
    };
  }

  // ========== Match.js - Pattern Matching ==========
  const _ = {};

  function patternToString(p) {
    if (p === _) return '_';
    if (p === null) return 'null';
    if (p === undefined) return 'undefined';
    if (typeof p === 'function') return '<pred>';
    if (typeof p === 'string') return "'" + p + "'";
    if (typeof p === 'number') return String(p);
    if (Array.isArray(p)) return '[' + p.map(patternToString).join(', ') + ']';
    if (p && p.type === 'instance') return 'inst(' + (p.cls && p.cls.name || '?') + ')';
    return '?';
  }

  function countBindings(p) {
    if (p === _) return 1;
    if (typeof p === 'function') return 1;
    if (Array.isArray(p)) return p.reduce(function(s, x) { return s + countBindings(x); }, 0);
    if (p && p.type === 'instance') return p.patterns.reduce(function(s, x) { return s + countBindings(x); }, 0);
    if (p && p.type === 'many') return countBindings(p.pattern);
    if (p && p.type === 'rest') return 1;
    if (p && p.type === 'check') return countBindings(p.pattern);
    return 0;
  }

  function match(value) {
    var args = Array.prototype.slice.call(arguments, 1);
    if (args.length % 2 !== 0) {
      throw new Error('patterns and functions must come in pairs!');
    }

    for (var i = 0; i < args.length; i += 2) {
      var pattern = args[i];
      var bindings = matchPattern(pattern, value);
      if (bindings !== null) {
        var func = args[i + 1];
        if (func.length !== bindings.length) {
          throw new Error('Arity Error in pattern #' + (i/2 + 1));
        }
        return func.apply(null, bindings);
      }
    }
    throw new Error('No pattern matched: ' + JSON.stringify(value));
  }

  function matchPattern(pattern, value) {
    if (pattern === _) {
      return [value];
    }

    if (typeof pattern === 'function') {
      return pattern(value) ? [value] : null;
    }

    if (Array.isArray(pattern)) {
      if (!Array.isArray(value)) return null;

      var allBinds = [];
      var patternIndex = 0;
      var valueIndex = 0;

      while (patternIndex < pattern.length) {
        var curPattern = pattern[patternIndex];
        if (curPattern && curPattern.type === 'many') {
          var manyBinds = [];
          var innerPattern = curPattern.pattern;

          while (valueIndex < value.length) {
            var subBinds = matchPattern(innerPattern, value[valueIndex]);
            if (subBinds === null) break;
            manyBinds.push(subBinds);
            valueIndex++;
          }

          if (manyBinds.length === 0) {
            allBinds.push([]);
          } else {
            for (var col = 0; col < manyBinds[0].length; col++) {
              var column = manyBinds.map(function(row) { return row[col]; });
              allBinds.push(column);
            }
          }
          patternIndex++;
        } else if (curPattern && curPattern.type === 'rest') {
          allBinds.push(value.slice(valueIndex));
          valueIndex = value.length;
          patternIndex++;
        } else {
          if (valueIndex >= value.length) return null;
          var subBinds2 = matchPattern(curPattern, value[valueIndex]);
          if (subBinds2 === null) return null;
          allBinds.push.apply(allBinds, subBinds2);
          patternIndex++;
          valueIndex++;
        }
      }

      if (valueIndex !== value.length && !pattern.some(function(p) { return p && p.type === 'rest'; })) {
        return null;
      }

      return allBinds;
    }

    if (pattern && pattern.type === 'instance') {
      if (!(value instanceof pattern.cls)) return null;
      var deconstructed = value.deconstruct();
      if (pattern.patterns.length !== deconstructed.length) return null;

      var allBindings = [];
      for (var i = 0; i < pattern.patterns.length; i++) {
        var subBindings = matchPattern(pattern.patterns[i], deconstructed[i]);
        if (subBindings === null) return null;
        allBindings.push.apply(allBindings, subBindings);
      }
      return allBindings;
    }

    if (pattern && pattern.type === 'range') {
      if (typeof value === 'number' && value >= pattern.min && value <= pattern.max) {
        return [];
      }
      return null;
    }

    if (pattern && pattern.type === 'check') {
      var bindings = matchPattern(pattern.pattern, value);
      if (bindings === null) return null;
      if (pattern.predicate(value)) return bindings;
      return null;
    }

    return value === pattern ? [] : null;
  }

  function inst(cls) {
    var patterns = Array.prototype.slice.call(arguments, 1);
    return { type: 'instance', cls: cls, patterns: patterns };
  }

  function many(pattern) {
    return { type: 'many', pattern: pattern };
  }

  function range(min, max) {
    return { type: 'range', min: min, max: max };
  }

  function when(pattern, predicate) {
    return { type: 'check', pattern: pattern, predicate: predicate };
  }

  function rest(name) {
    return { type: 'rest', name: name };
  }

  // ========== AST Classes ==========
  function Program(statements) {
    this.statements = statements;
  }
  Program.prototype.deconstruct = function() { return [this.statements]; };

  function BundleDecl(name, outputs, expr) {
    this.name = name;
    this.outputs = outputs;
    this.expr = expr;
  }
  BundleDecl.prototype.deconstruct = function() { return [this.name, this.outputs, this.expr]; };

  function SpindleDef(name, params, body) {
    this.name = name;
    this.params = params;
    this.body = body;
  }
  SpindleDef.prototype.deconstruct = function() { return [this.name, this.params, this.body]; };

  function ReturnAssign(index, expr) {
    this.index = index;
    this.expr = expr;
  }
  ReturnAssign.prototype.deconstruct = function() { return [this.index, this.expr]; };

  function NumberLit(value) {
    this.value = value;
  }
  NumberLit.prototype.deconstruct = function() { return [this.value]; };

  function StringLit(value) {
    this.value = value;
  }
  StringLit.prototype.deconstruct = function() { return [this.value]; };

  function Identifier(name) {
    this.name = name;
  }
  Identifier.prototype.deconstruct = function() { return [this.name]; };

  function BundleLit(elements) {
    this.elements = elements;
  }
  BundleLit.prototype.deconstruct = function() { return [this.elements]; };

  function StrandAccess(bundle, accessor) {
    this.bundle = bundle;
    this.accessor = accessor;
  }
  StrandAccess.prototype.deconstruct = function() { return [this.bundle, this.accessor]; };

  function IndexAccessor(value) {
    this.value = value;
  }
  IndexAccessor.prototype.deconstruct = function() { return [this.value]; };

  function NameAccessor(value) {
    this.value = value;
  }
  NameAccessor.prototype.deconstruct = function() { return [this.value]; };

  function ExprAccessor(value) {
    this.value = value;
  }
  ExprAccessor.prototype.deconstruct = function() { return [this.value]; };

  function BinaryOp(left, op, right) {
    this.left = left;
    this.op = op;
    this.right = right;
  }
  BinaryOp.prototype.deconstruct = function() { return [this.left, this.op, this.right]; };

  function UnaryOp(op, operand) {
    this.op = op;
    this.operand = operand;
  }
  UnaryOp.prototype.deconstruct = function() { return [this.op, this.operand]; };

  function SpindleCall(name, args) {
    this.name = name;
    this.args = args;
  }
  SpindleCall.prototype.deconstruct = function() { return [this.name, this.args]; };

  function CallExtract(call, index) {
    this.call = call;
    this.index = index;
  }
  CallExtract.prototype.deconstruct = function() { return [this.call, this.index]; };

  function RemapExpr(base, remappings) {
    this.base = base;
    this.remappings = remappings;
  }
  RemapExpr.prototype.deconstruct = function() { return [this.base, this.remappings]; };

  function ChainExpr(base, patterns) {
    this.base = base;
    this.patterns = patterns;
  }
  ChainExpr.prototype.deconstruct = function() { return [this.base, this.patterns]; };

  function RemapArg(domain, expr) {
    this.domain = domain;
    this.expr = expr;
  }
  RemapArg.prototype.deconstruct = function() { return [this.domain, this.expr]; };

  function PatternBlock(outputs) {
    this.outputs = outputs;
  }
  PatternBlock.prototype.deconstruct = function() { return [this.outputs]; };

  function PatternOutput(type, value) {
    this.type = type;
    this.value = value;
  }
  PatternOutput.prototype.deconstruct = function() { return [this.type, this.value]; };

  function RangeExpr(start, end) {
    this.start = start;  // null for open start
    this.end = end;      // null for open end
  }
  RangeExpr.prototype.deconstruct = function() { return [this.start, this.end]; };

  var AST = {
    Program: Program,
    BundleDecl: BundleDecl,
    SpindleDef: SpindleDef,
    ReturnAssign: ReturnAssign,
    NumberLit: NumberLit,
    StringLit: StringLit,
    Identifier: Identifier,
    BundleLit: BundleLit,
    StrandAccess: StrandAccess,
    IndexAccessor: IndexAccessor,
    NameAccessor: NameAccessor,
    ExprAccessor: ExprAccessor,
    BinaryOp: BinaryOp,
    UnaryOp: UnaryOp,
    SpindleCall: SpindleCall,
    CallExtract: CallExtract,
    RemapExpr: RemapExpr,
    ChainExpr: ChainExpr,
    RemapArg: RemapArg,
    PatternBlock: PatternBlock,
    PatternOutput: PatternOutput,
    RangeExpr: RangeExpr
  };

  // ========== IR Classes ==========
  function unionAll() {
    var result = new Set();
    for (var i = 0; i < arguments.length; i++) {
      var s = arguments[i];
      s.forEach(function(v) { result.add(v); });
    }
    return result;
  }

  function IRProgram(bundles, spindles, order, resources) {
    this.bundles = bundles || new Map();
    this.spindles = spindles || new Map();
    this.order = order || [];
    this.resources = resources || [];
  }
  IRProgram.prototype.deconstruct = function() {
    return [Array.from(this.bundles.values()), Array.from(this.spindles.values()), this.order, this.resources];
  };
  IRProgram.prototype.toJSON = function() {
    var bundlesObj = {};
    this.bundles.forEach(function(v, k) {
      bundlesObj[k] = v.toJSON();
    });
    var spindlesObj = {};
    this.spindles.forEach(function(v, k) {
      spindlesObj[k] = v.toJSON();
    });
    return {
      bundles: bundlesObj,
      spindles: spindlesObj,
      order: this.order,
      resources: this.resources
    };
  };

  function IRBundle(name, strands) {
    this.name = name;
    this.strands = strands || [];
  }
  IRBundle.prototype.deconstruct = function() { return [this.name, this.strands]; };
  IRBundle.prototype.toJSON = function() {
    return {
      name: this.name,
      strands: this.strands.map(function(s) { return s.toJSON(); })
    };
  };

  function IRStrand(name, index, expr) {
    this.name = name;
    this.index = index;
    this.expr = expr;
  }
  IRStrand.prototype.deconstruct = function() { return [this.name, this.index, this.expr]; };
  IRStrand.prototype.toJSON = function() {
    return {
      name: String(this.name),
      index: this.index,
      expr: this.expr.toJSON()
    };
  };

  function IRSpindle(name, params, locals, returns) {
    this.name = name;
    this.params = params || [];
    this.locals = locals || [];
    this.returns = returns || [];
  }
  IRSpindle.prototype.deconstruct = function() { return [this.name, this.params, this.locals, this.returns]; };
  IRSpindle.prototype.toJSON = function() {
    return {
      name: this.name,
      params: this.params,
      locals: this.locals.map(function(l) { return l.toJSON(); }),
      returns: this.returns.map(function(r) { return r.toJSON(); })
    };
  };

  function IRNum(value) {
    this.value = value;
  }
  IRNum.prototype.freeVars = function() { return new Set(); };
  IRNum.prototype.deconstruct = function() { return [this.value]; };
  IRNum.prototype.toJSON = function() { return { type: 'num', value: this.value }; };

  function IRParam(name) {
    this.name = name;
  }
  IRParam.prototype.freeVars = function() { return new Set(); };
  IRParam.prototype.deconstruct = function() { return [this.name]; };
  IRParam.prototype.toJSON = function() { return { type: 'param', name: this.name }; };

  function IRIndex(bundle, indexExpr, fieldName) {
    this.bundle = bundle;
    this.indexExpr = indexExpr;
    this.fieldName = fieldName || null;  // Original field name if from named access
  }
  Object.defineProperty(IRIndex.prototype, 'key', {
    get: function() {
      if (!(this.indexExpr instanceof IRNum)) {
        throw new Error('Cannot get key for dynamic index into "' + this.bundle + '"');
      }
      return this.bundle + '.' + this.indexExpr.value;
    }
  });
  IRIndex.prototype.freeVars = function() {
    var indexVars = this.indexExpr.freeVars();
    if (this.indexExpr instanceof IRNum) {
      return unionAll(indexVars, new Set([this.bundle + '.' + this.indexExpr.value]));
    } else {
      return unionAll(indexVars, new Set([this.bundle]));
    }
  };
  IRIndex.prototype.deconstruct = function() { return [this.bundle, this.indexExpr]; };
  IRIndex.prototype.toJSON = function() {
    // For "me" bundle with static index, convert to field name
    if (this.bundle === 'me' && this.indexExpr instanceof IRNum) {
      // Use preserved field name if available, otherwise fall back to index lookup
      if (this.fieldName) {
        return { type: 'index', bundle: 'me', field: this.fieldName };
      }
      var meFields = ['x', 'y', 'u', 'v', 'w', 'h', 't', 'rate', 'duration'];
      var idx = this.indexExpr.value;
      var field = meFields[idx] || String(idx);
      return { type: 'index', bundle: 'me', field: field };
    }
    return {
      type: 'index',
      bundle: this.bundle,
      indexExpr: this.indexExpr.toJSON()
    };
  };

  function IRBinaryOp(op, left, right) {
    this.op = op;
    this.left = left;
    this.right = right;
    this._freeVars = null;
  }
  IRBinaryOp.prototype.freeVars = function() {
    if (this._freeVars === null) {
      this._freeVars = unionAll(this.left.freeVars(), this.right.freeVars());
    }
    return this._freeVars;
  };
  IRBinaryOp.prototype.deconstruct = function() { return [this.op, this.left, this.right]; };
  IRBinaryOp.prototype.toJSON = function() {
    return { type: 'binary', op: this.op, left: this.left.toJSON(), right: this.right.toJSON() };
  };

  function IRUnaryOp(op, operand) {
    this.op = op;
    this.operand = operand;
  }
  IRUnaryOp.prototype.freeVars = function() { return this.operand.freeVars(); };
  IRUnaryOp.prototype.deconstruct = function() { return [this.op, this.operand]; };
  IRUnaryOp.prototype.toJSON = function() {
    return { type: 'unary', op: this.op, operand: this.operand.toJSON() };
  };

  function IRCall(spindle, args) {
    this.spindle = spindle;
    this.args = args || [];
    this._freeVars = null;
  }
  IRCall.prototype.freeVars = function() {
    if (this._freeVars === null) {
      this._freeVars = unionAll.apply(null, this.args.map(function(a) { return a.freeVars(); }));
    }
    return this._freeVars;
  };
  IRCall.prototype.deconstruct = function() { return [this.spindle, this.args]; };
  IRCall.prototype.toJSON = function() {
    return {
      type: 'call',
      spindle: this.spindle,
      args: this.args.map(function(a) { return a.toJSON(); })
    };
  };

  function IRBuiltin(name, args) {
    this.name = name;
    this.args = args || [];
    this._freeVars = null;
  }
  IRBuiltin.prototype.freeVars = function() {
    if (this._freeVars === null) {
      this._freeVars = unionAll.apply(null, this.args.map(function(a) { return a.freeVars(); }));
    }
    return this._freeVars;
  };
  IRBuiltin.prototype.deconstruct = function() { return [this.name, this.args]; };
  IRBuiltin.prototype.toJSON = function() {
    return {
      type: 'builtin',
      name: this.name,
      args: this.args.map(function(a) { return a.toJSON(); })
    };
  };

  function IRRemap(base, substitutions) {
    this.base = base;
    this.substitutions = substitutions;
    this._freeVars = null;
  }
  IRRemap.prototype.freeVars = function() {
    if (this._freeVars === null) {
      var self = this;
      var baseVars = this.base.freeVars();
      var result = new Set();
      baseVars.forEach(function(v) {
        if (!self.substitutions.has(v)) result.add(v);
      });
      this.substitutions.forEach(function(expr) {
        expr.freeVars().forEach(function(v) { result.add(v); });
      });
      this._freeVars = result;
    }
    return this._freeVars;
  };
  IRRemap.prototype.deconstruct = function() {
    var obj = {};
    this.substitutions.forEach(function(v, k) { obj[k] = v; });
    return [this.base, obj];
  };
  IRRemap.prototype.toJSON = function() {
    var subs = {};
    this.substitutions.forEach(function(v, k) { subs[k] = v.toJSON(); });
    return { type: 'remap', base: this.base.toJSON(), substitutions: subs };
  };

  function IRExtract(call, index) {
    this.call = call;
    this.index = index;
  }
  IRExtract.prototype.freeVars = function() { return this.call.freeVars(); };
  IRExtract.prototype.deconstruct = function() { return [this.call, this.index]; };
  IRExtract.prototype.toJSON = function() {
    return { type: 'extract', call: this.call.toJSON(), index: this.index };
  };

  function IRTexture(resourceId, uExpr, vExpr, channel) {
    this.resourceId = resourceId;
    this.uExpr = uExpr;
    this.vExpr = vExpr;
    this.channel = channel;
    this._freeVars = null;
  }
  IRTexture.prototype.freeVars = function() {
    if (this._freeVars === null) {
      this._freeVars = unionAll(this.uExpr.freeVars(), this.vExpr.freeVars());
    }
    return this._freeVars;
  };
  IRTexture.prototype.deconstruct = function() { return [this.resourceId, this.uExpr, this.vExpr, this.channel]; };
  IRTexture.prototype.toJSON = function() {
    return {
      type: 'texture',
      resourceId: this.resourceId,
      u: this.uExpr.toJSON(),
      v: this.vExpr.toJSON(),
      channel: this.channel
    };
  };

  function IRCamera(uExpr, vExpr, channel) {
    this.uExpr = uExpr;
    this.vExpr = vExpr;
    this.channel = channel;
    this._freeVars = null;
  }
  IRCamera.prototype.freeVars = function() {
    if (this._freeVars === null) {
      this._freeVars = unionAll(this.uExpr.freeVars(), this.vExpr.freeVars());
    }
    return this._freeVars;
  };
  IRCamera.prototype.deconstruct = function() { return [this.uExpr, this.vExpr, this.channel]; };
  IRCamera.prototype.toJSON = function() {
    return {
      type: 'camera',
      u: this.uExpr.toJSON(),
      v: this.vExpr.toJSON(),
      channel: this.channel
    };
  };

  function IRMicrophone(offsetExpr, channel) {
    this.offsetExpr = offsetExpr;
    this.channel = channel;
    this._freeVars = null;
  }
  IRMicrophone.prototype.freeVars = function() {
    if (this._freeVars === null) {
      this._freeVars = this.offsetExpr.freeVars();
    }
    return this._freeVars;
  };
  IRMicrophone.prototype.deconstruct = function() { return [this.offsetExpr, this.channel]; };
  IRMicrophone.prototype.toJSON = function() {
    return {
      type: 'microphone',
      offset: this.offsetExpr.toJSON(),
      channel: this.channel
    };
  };

  var IR = {
    IRProgram: IRProgram,
    IRBundle: IRBundle,
    IRStrand: IRStrand,
    IRSpindle: IRSpindle,
    IRNum: IRNum,
    IRParam: IRParam,
    IRIndex: IRIndex,
    IRBinaryOp: IRBinaryOp,
    IRUnaryOp: IRUnaryOp,
    IRCall: IRCall,
    IRBuiltin: IRBuiltin,
    IRRemap: IRRemap,
    IRExtract: IRExtract,
    IRTexture: IRTexture,
    IRCamera: IRCamera,
    IRMicrophone: IRMicrophone
  };

  // ========== Grammar ==========
  var grammarText = 'WEFT {\n\
\n\
  Program = Statement*\n\
\n\
  Statement = BundleDecl | SpindleDef\n\
\n\
  BundleDecl\n\
    = ident "." ident "=" Expr       -- shorthand\n\
    | ident "[" OutputList "]" "=" Expr  -- full\n\
\n\
  OutputList = outputItem ("," outputItem)*\n\
\n\
  outputItem = ident | integer\n\
\n\
  IdentList = ident ("," ident)*\n\
\n\
  Expr\n\
    = ChainExpr\n\
\n\
  ChainExpr\n\
    = ComparisonExpr ("->" PatternBlock)+  -- chain\n\
    | ComparisonExpr                        -- base\n\
\n\
  ComparisonExpr\n\
    = AddExpr (compareOp AddExpr)*\n\
\n\
  compareOp = ">=" | "<=" | "==" | "!=" | ">" | "<"\n\
\n\
  AddExpr\n\
    = MultExpr (addOp MultExpr)*\n\
\n\
  addOp = "+" | "-"\n\
\n\
  MultExpr\n\
    = ExpoExpr (multOp ExpoExpr)*\n\
\n\
  multOp = "*" | "/" | "%"\n\
\n\
  ExpoExpr\n\
    = UnaryExpr ("^" UnaryExpr)*\n\
\n\
  UnaryExpr\n\
    = "-" UnaryExpr  -- negate\n\
    | PrimaryExpr    -- base\n\
\n\
  PrimaryExpr\n\
    = "(" Expr ")"           -- paren\n\
    | RemapExpr              -- remap\n\
    | StrandAccess           -- strandAccess\n\
    | SpindleCall            -- call\n\
    | BundleLit              -- bundleLit\n\
    | stringLit              -- string\n\
    | RangeExpr              -- range\n\
    | Number                 -- number\n\
    | ident                  -- ident\n\
\n\
  stringLit = "\\"" (~"\\"" any)* "\\""\n\
\n\
  StrandAccess\n\
    = SpindleCall "." signedInt  -- callIndex\n\
    | BundleLit "." signedInt    -- litIndex\n\
    | BundleLit "." "(" Expr ")" -- litExpr\n\
    | ident "." ident            -- name\n\
    | ident "." signedInt        -- index\n\
    | ident "." "(" Expr ")"     -- expr\n\
    | "." ident                  -- bareName\n\
    | "." signedInt              -- bareIndex\n\
\n\
  signedInt = "-"? integer\n\
\n\
  RemapExpr\n\
    = StrandAccess "(" RemapArgList ")"\n\
\n\
  RemapArgList\n\
    = RemapArg ("," RemapArg)*\n\
\n\
  RemapArg\n\
    = StrandAccess "~" Expr\n\
\n\
  RangeExpr\n\
    = signedInt ".." signedInt  -- bounded\n\
    | signedInt ".."            -- from\n\
    | ".." signedInt            -- to\n\
    | ".."                      -- all\n\
\n\
  BundleLit\n\
    = "[" ExprList "]"\n\
\n\
  ExprList\n\
    = Expr ("," Expr)*\n\
\n\
  SpindleCall\n\
    = ident "(" ExprList? ")"\n\
\n\
  PatternBlock\n\
    = "{" PatternOutputList "}"\n\
\n\
  PatternOutputList\n\
    = PatternOutput ("," PatternOutput)*\n\
\n\
  PatternOutput\n\
    = Expr                      -- expr\n\
\n\
  SpindleDef\n\
    = "spindle" ident "(" IdentList? ")" "{" Body "}"\n\
\n\
  Body\n\
    = BodyStmt*\n\
\n\
  BodyStmt\n\
    = "return" "." integer "=" Expr  -- returnAssign\n\
    | BundleDecl                     -- bundleDecl\n\
\n\
  Number = digit+ ("." digit+)?\n\
\n\
  integer = digit+\n\
\n\
  ident = letter (alnum | "_")*\n\
\n\
  space += comment\n\
  comment = "//" (~"\\n" any)* "\\n"?\n\
}';

  // ========== Parser ==========
  var grammar = null;
  var semantics = null;

  function initParser() {
    if (grammar !== null) return;

    if (typeof ohm === 'undefined') {
      throw new Error('Ohm.js is required but not loaded. Make sure ohm is available globally.');
    }

    grammar = ohm.grammar(grammarText);
    semantics = grammar.createSemantics().addOperation('toAST', {
      _iter: function() {
        var children = Array.prototype.slice.call(arguments);
        return children.map(function(c) { return c.toAST(); });
      },

      _terminal: function() {
        return this.sourceString;
      },

      Program: function(stmts) {
        return new Program(stmts.toAST());
      },

      BundleDecl_shorthand: function(name, _dot, strandName, _eq, expr) {
        return new BundleDecl(name.sourceString, [strandName.sourceString], expr.toAST());
      },

      BundleDecl_full: function(name, _lb, outputs, _rb, _eq, expr) {
        return new BundleDecl(name.sourceString, outputs.toAST(), expr.toAST());
      },

      OutputList: function(first, _commas, rest) {
        return [first.toAST()].concat(rest.toAST());
      },

      outputItem: function(item) {
        var s = item.sourceString;
        var n = parseInt(s);
        return isNaN(n) ? s : n;
      },

      SpindleDef: function(_spindle, name, _lp, params, _rp, _lb, body, _rb) {
        return new SpindleDef(name.sourceString, params.toAST()[0] || [], body.toAST());
      },

      IdentList: function(first, _commas, rest) {
        return [first.sourceString].concat(rest.children.map(function(c) { return c.sourceString; }));
      },

      BodyStmt_bundleDecl: function(decl) {
        return decl.toAST();
      },

      BodyStmt_returnAssign: function(_return, _at, index, _eq, expr) {
        return new ReturnAssign(parseInt(index.sourceString), expr.toAST());
      },

      ChainExpr_chain: function(base, _arrows, patterns) {
        return new ChainExpr(base.toAST(), patterns.toAST());
      },

      ChainExpr_base: function(expr) {
        return expr.toAST();
      },

      ComparisonExpr: function(first, ops, rest) {
        var result = first.toAST();
        var opsList = ops.toAST();
        var restList = rest.toAST();
        for (var i = 0; i < opsList.length; i++) {
          result = new BinaryOp(result, opsList[i], restList[i]);
        }
        return result;
      },

      compareOp: function(_op) {
        return this.sourceString;
      },

      AddExpr: function(first, ops, rest) {
        var result = first.toAST();
        var opsList = ops.toAST();
        var restList = rest.toAST();
        for (var i = 0; i < opsList.length; i++) {
          result = new BinaryOp(result, opsList[i], restList[i]);
        }
        return result;
      },

      addOp: function(_op) {
        return this.sourceString;
      },

      MultExpr: function(first, ops, rest) {
        var result = first.toAST();
        var opsList = ops.toAST();
        var restList = rest.toAST();
        for (var i = 0; i < opsList.length; i++) {
          result = new BinaryOp(result, opsList[i], restList[i]);
        }
        return result;
      },

      multOp: function(_op) {
        return this.sourceString;
      },

      ExpoExpr: function(first, _carets, rest) {
        var restList = rest.toAST();
        if (restList.length === 0) {
          return first.toAST();
        }
        var result = restList[restList.length - 1];
        for (var i = restList.length - 2; i >= 0; i--) {
          result = new BinaryOp(restList[i], '^', result);
        }
        return new BinaryOp(first.toAST(), '^', result);
      },

      UnaryExpr_negate: function(_minus, operand) {
        return new UnaryOp('-', operand.toAST());
      },

      UnaryExpr_base: function(expr) {
        return expr.toAST();
      },

      PrimaryExpr_paren: function(_lp, expr, _rp) {
        return expr.toAST();
      },

      PrimaryExpr_bundleLit: function(bundle) {
        return bundle.toAST();
      },

      PrimaryExpr_call: function(call) {
        return call.toAST();
      },

      PrimaryExpr_remap: function(remap) {
        return remap.toAST();
      },

      PrimaryExpr_strandAccess: function(access) {
        return access.toAST();
      },

      PrimaryExpr_number: function(num) {
        return num.toAST();
      },

      PrimaryExpr_ident: function(id) {
        return id.toAST();
      },

      PrimaryExpr_string: function(str) {
        return str.toAST();
      },

      PrimaryExpr_range: function(range) {
        return range.toAST();
      },

      stringLit: function(_open, chars, _close) {
        return new StringLit(chars.sourceString);
      },

      StrandAccess_callIndex: function(call, _dot, index) {
        return new CallExtract(call.toAST(), index.toAST());
      },

      StrandAccess_litIndex: function(bundleLit, _dot, index) {
        return new StrandAccess(bundleLit.toAST(), new IndexAccessor(index.toAST()));
      },

      StrandAccess_litExpr: function(bundleLit, _dot, _lp, expr, _rp) {
        return new StrandAccess(bundleLit.toAST(), new ExprAccessor(expr.toAST()));
      },

      StrandAccess_name: function(bundle, _dot, name) {
        return new StrandAccess(bundle.sourceString, new NameAccessor(name.sourceString));
      },

      StrandAccess_index: function(bundle, _dot, index) {
        return new StrandAccess(bundle.sourceString, new IndexAccessor(index.toAST()));
      },

      StrandAccess_expr: function(bundle, _dot, _lp, expr, _rp) {
        return new StrandAccess(bundle.sourceString, new ExprAccessor(expr.toAST()));
      },

      StrandAccess_bareName: function(_dot, name) {
        return new StrandAccess(null, new NameAccessor(name.sourceString));
      },

      StrandAccess_bareIndex: function(_dot, index) {
        return new StrandAccess(null, new IndexAccessor(index.toAST()));
      },

      RemapExpr: function(base, _lp, args, _rp) {
        return new RemapExpr(base.toAST(), args.toAST());
      },

      RemapArgList: function(first, _commas, rest) {
        return [first.toAST()].concat(rest.toAST());
      },

      RemapArg: function(coord, _tilde, expr) {
        return new RemapArg(coord.toAST(), expr.toAST());
      },

      RangeExpr_bounded: function(start, _dots, end) {
        return new RangeExpr(start.toAST(), end.toAST());
      },

      RangeExpr_from: function(start, _dots) {
        return new RangeExpr(start.toAST(), null);
      },

      RangeExpr_to: function(_dots, end) {
        return new RangeExpr(null, end.toAST());
      },

      RangeExpr_all: function(_dots) {
        return new RangeExpr(null, null);
      },

      BundleLit: function(_lb, exprs, _rb) {
        return new BundleLit(exprs.toAST());
      },

      ExprList: function(first, _commas, rest) {
        return [first.toAST()].concat(rest.toAST());
      },

      SpindleCall: function(name, _lp, args, _rp) {
        return new SpindleCall(name.sourceString, args.toAST()[0] || []);
      },

      PatternBlock: function(_lb, outputs, _rb) {
        return new PatternBlock(outputs.toAST());
      },

      PatternOutputList: function(first, _commas, rest) {
        return [first.toAST()].concat(rest.toAST());
      },

      PatternOutput_expr: function(expr) {
        return new PatternOutput('expr', expr.toAST());
      },

      signedInt: function(_sign, _digits) {
        return parseInt(this.sourceString);
      },

      Number: function(_intPart, _dot, _fracPart) {
        return new NumberLit(parseFloat(this.sourceString));
      },

      ident: function(_first, _rest) {
        return new Identifier(this.sourceString);
      }
    });
  }

  function parse(sourceCode) {
    initParser();
    var matchResult = grammar.match(sourceCode);
    if (matchResult.failed()) {
      throw new Error(matchResult.message);
    }
    return semantics(matchResult).toAST();
  }

  // ========== Lowering ==========
  var BUILTINS = new Set([
    'sin', 'cos', 'tan', 'abs', 'floor', 'ceil', 'sqrt', 'pow',
    'min', 'max', 'lerp', 'clamp', 'step', 'smoothstep', 'fract', 'mod',
    'osc', 'cache'
  ]);

  var ME_STRANDS = {
    x: 0, y: 1, u: 2, v: 3, w: 4, h: 5,
    t: 6,
    i: 0, rate: 7, duration: 8, sampleRate: 7
  };

  var RESOURCE_BUILTINS = {
    texture: { width: 3, argCount: 3 },
    camera: { width: 3, argCount: 2 },
    microphone: { width: 2, argCount: 1 }  // offset -> (left, right)
  };

  function LoweringContext() {
    this.bundles = new Map();
    this.spindles = new Map();
    this.bundleInfo = new Map();
    this.spindleInfo = new Map();
    this.declarations = [];
    this.scope = null;
    this.resources = [];
    this.resourceIndex = new Map();
  }

  LoweringContext.prototype.error = function(msg) { throw new Error(msg); };

  LoweringContext.prototype.lowerProgram = function(ast) {
    var self = this;
    ast.statements.forEach(function(stmt) {
      if (stmt instanceof BundleDecl) self.registerBundle(stmt);
      else if (stmt instanceof SpindleDef) self.registerSpindle(stmt);
    });

    ast.statements.forEach(function(stmt) {
      if (stmt instanceof BundleDecl) self.lowerBundleDecl(stmt);
      else if (stmt instanceof SpindleDef) self.lowerSpindleDef(stmt);
    });

    return new IRProgram(this.bundles, this.spindles, this.topologicalSort(), this.resources);
  };

  LoweringContext.prototype.registerBundle = function(decl) {
    var info = this.bundleInfo.get(decl.name) || { width: 0, strandIndex: new Map() };
    this.bundleInfo.set(decl.name, info);

    decl.outputs.forEach(function(out) {
      if (typeof out === 'number') {
        info.width = Math.max(info.width, out + 1);
        info.strandIndex.set(out, out);
      } else {
        if (!info.strandIndex.has(out)) info.strandIndex.set(out, info.width++);
      }
    });
  };

  LoweringContext.prototype.registerSpindle = function(def) {
    var self = this;
    if (this.spindleInfo.has(def.name)) this.error('Duplicate spindle: ' + def.name);

    var maxIdx = -1;
    var indices = new Set();

    def.body.forEach(function(stmt) {
      if (stmt instanceof ReturnAssign) {
        indices.add(stmt.index);
        maxIdx = Math.max(maxIdx, stmt.index);
      }
    });

    for (var i = 0; i <= maxIdx; i++) {
      if (!indices.has(i)) this.error('Spindle "' + def.name + '" missing return.' + i);
    }

    this.spindleInfo.set(def.name, { params: new Set(def.params), width: maxIdx + 1 });
  };

  LoweringContext.prototype.lowerBundleDecl = function(decl) {
    var self = this;
    var info = this.bundleInfo.get(decl.name);
    var exprs = this.lowerToStrands(decl.expr, decl.outputs.length);

    var bundle = this.bundles.get(decl.name) || new IRBundle(decl.name, []);
    this.bundles.set(decl.name, bundle);

    var strandNames = new Set();
    var declStrands = [];

    decl.outputs.forEach(function(out, i) {
      var isIdx = typeof out === 'number';
      var name = isIdx ? (bundle.strands.find(function(s) { return s.index === out; })?.name ?? out) : out;
      var idx = isIdx ? out : info.strandIndex.get(out);
      strandNames.add(name);

      var strand = new IRStrand(name, idx, exprs[i]);
      var existing = bundle.strands.findIndex(function(s) { return isIdx ? s.index === out : s.name === out; });
      if (existing >= 0) bundle.strands[existing] = strand;
      else bundle.strands.push(strand);
      declStrands.push(strand);
    });

    this.declarations.push({ bundle: decl.name, strandNames: strandNames, strands: declStrands });
  };

  LoweringContext.prototype.lowerSpindleDef = function(def) {
    var self = this;
    var info = this.spindleInfo.get(def.name);
    this.scope = { params: info.params, locals: new Map() };

    var locals = [];
    var returns = new Array(info.width).fill(null);

    def.body.forEach(function(stmt) {
      if (stmt instanceof BundleDecl) {
        var exprs = self.lowerToStrands(stmt.expr, stmt.outputs.length);
        var strandIndex = new Map();
        var strands = stmt.outputs.map(function(out, i) {
          strandIndex.set(out, i);
          return new IRStrand(out, i, exprs[i]);
        });
        locals.push(new IRBundle(stmt.name, strands));
        self.scope.locals.set(stmt.name, { strandIndex: strandIndex });
      } else if (stmt instanceof ReturnAssign) {
        if (self.inferWidth(stmt.expr) !== 1) {
          self.error('return.' + stmt.index + ' expects 1 value');
        }
        returns[stmt.index] = self.lowerExpr(stmt.expr);
      }
    });

    this.scope = null;
    this.spindles.set(def.name, new IRSpindle(def.name, def.params, locals, returns));
  };

  LoweringContext.prototype.lowerExpr = function(expr, subs) {
    var self = this;
    subs = subs || null;

    if (expr instanceof StrandAccess && expr.bundle === null) {
      if (!subs) this.error('Bare strand access outside pattern context');
      return match(expr.accessor,
        inst(IndexAccessor, _), function(idx) {
          var resolved = idx < 0 ? subs.length + idx : idx;
          if (resolved < 0 || resolved >= subs.length) {
            self.error('Strand index .' + idx + ' out of range');
          }
          return subs[resolved];
        },
        inst(NameAccessor, _), function(name) { return self.error('Bare .' + name + ' not supported (use index)'); },
        inst(ExprAccessor, _), function(indexExpr) {
          return self.buildSelector(subs, self.lowerExpr(indexExpr, subs));
        }
      );
    }

    return match(expr,
      inst(NumberLit, _), function(v) { return new IRNum(v); },

      inst(Identifier, _), function(name) {
        if (self.scope && self.scope.params && self.scope.params.has(name)) return new IRParam(name);
        self.error('Unknown identifier: ' + name);
      },

      inst(StrandAccess, _, _), function(_b, _a) { return self.lowerStrandAccess(expr); },

      inst(BinaryOp, _, _, _), function(l, op, r) {
        return new IRBinaryOp(op, self.lowerExpr(l, subs), self.lowerExpr(r, subs));
      },

      inst(UnaryOp, _, _), function(op, x) {
        return new IRUnaryOp(op, self.lowerExpr(x, subs));
      },

      inst(SpindleCall, _, _), function(name, args) {
        var irCall = self.lowerCall(name, args, function(a) { return self.lowerExpr(a, subs); });
        if (BUILTINS.has(name)) return irCall;
        var info = self.spindleInfo.get(name);
        if (info && info.width === 1) {
          return new IRExtract(irCall, 0);
        }
        self.error('Spindle "' + name + '" returns ' + (info?.width) + ' values, cannot use in single-value context');
      },

      inst(CallExtract, _, _), function(call, idx) {
        var irCall = self.lowerExpr(call, subs);
        if (call instanceof SpindleCall) {
          var info = self.spindleInfo.get(call.name);
          if (info && (idx < 0 || idx >= info.width)) {
            self.error('Index ' + idx + ' out of range for "' + call.name + '"');
          }
        }
        return new IRExtract(irCall, idx);
      },

      inst(RangeExpr, _, _), function(_start, _end) {
        self.error('Range expressions (0..3) are only valid inside pattern blocks');
      },

      inst(RemapExpr, _, _), function(base, remaps) {
        var irBase;
        if (base.bundle === null) {
          if (!subs) self.error('Bare strand access outside pattern context');
          irBase = match(base.accessor,
            inst(IndexAccessor, _), function(idx) {
              var resolved = idx < 0 ? subs.length + idx : idx;
              if (resolved < 0 || resolved >= subs.length) {
                self.error('Strand index .' + idx + ' out of range');
              }
              return subs[resolved];
            },
            inst(NameAccessor, _), function(name) { return self.error('Bare .' + name + ' not supported'); },
            inst(ExprAccessor, _), function(indexExpr) {
              return self.buildSelector(subs, self.lowerExpr(indexExpr, subs));
            }
          );
        } else {
          irBase = self.lowerStrandAccess(base);
        }

        var subMap = new Map();
        remaps.forEach(function(r) {
          if (!r || r.domain === undefined || r.expr === undefined) {
            self.error('Invalid remap arg');
          }
          var domainIR = self.lowerStrandAccess(r.domain);
          var exprIR = self.lowerExpr(r.expr, subs);
          subMap.set(domainIR.key, exprIR);
        });

        if (base.bundle === null) {
          return self.substituteInExpr(irBase, subMap);
        }

        return new IRRemap(irBase, subMap);
      },

      _, function(_n) { self.error('Cannot lower: ' + expr.constructor.name); }
    );
  };

  LoweringContext.prototype.lowerToStrands = function(expr, width, subs) {
    var self = this;
    subs = subs || null;

    return match(expr,
      inst(BundleLit, _), function(elements) {
        var result = [];
        elements.forEach(function(el) {
          var w = self.inferWidth(el);
          if (w === 1) result.push(self.lowerExpr(el, subs));
          else result.push.apply(result, self.lowerToStrands(el, w, subs));
        });
        if (result.length !== width) self.error('Width mismatch: got ' + result.length + ', expected ' + width);
        return result;
      },

      inst(ChainExpr, _, _), function(_b, _p) { return self.lowerChainExpr(expr, width); },

      inst(SpindleCall, _, _), function(name, args) {
        if (RESOURCE_BUILTINS[name]) {
          return self.lowerResourceCall(name, args, width, subs);
        }

        var info = self.spindleInfo.get(name);
        var isBuiltin = BUILTINS.has(name);
        var w = info?.width ?? (isBuiltin ? 1 : self.error('Unknown: ' + name));
        if (w !== width) self.error('"' + name + '" returns ' + w + ', expected ' + width);
        var call = self.lowerCall(name, args, function(a) { return self.lowerExpr(a, subs); });
        if (isBuiltin) return [call];
        return Array.from({ length: w }, function(_, i) { return new IRExtract(call, i); });
      },

      inst(Identifier, 'me'), function() {
        var meWidth = Object.keys(ME_STRANDS).length;
        if (meWidth < width) self.error('me has ' + meWidth + ' strands, expected ' + width);
        return Array.from({ length: width }, function(_, i) { return new IRIndex('me', new IRNum(i)); });
      },

      inst(Identifier, _), function(name) {
        var info = self.bundleInfo.get(name);
        if (!info) self.error('Unknown bundle: ' + name);
        if (info.width !== width) self.error(name + ' has ' + info.width + ' strands, expected ' + width);
        return Array.from({ length: width }, function(_, i) { return new IRIndex(name, new IRNum(i)); });
      },

      _, function(_n) {
        if (width === 1) return [self.lowerExpr(expr, subs)];
        self.error('Cannot expand ' + expr.constructor.name + ' to ' + width + ' strands');
      }
    );
  };

  // Find all RangeExpr nodes in an expression tree
  // Returns array of { range: RangeExpr, inExprAccessor: boolean, bundleName: string|null }
  LoweringContext.prototype.findRanges = function(expr) {
    var self = this;
    var ranges = [];

    function visit(node, inExprAccessor, bundleName) {
      if (node instanceof RangeExpr) {
        ranges.push({ range: node, inExprAccessor: inExprAccessor, bundleName: bundleName });
        return;
      }

      if (node instanceof StrandAccess) {
        // Check if accessor is ExprAccessor containing a RangeExpr
        if (node.accessor instanceof ExprAccessor) {
          var bundle = node.bundle;
          var bundleStr = (typeof bundle === 'string') ? bundle : null;
          visit(node.accessor.value, true, bundleStr);
        }
        // Also check BundleLit bundles
        if (node.bundle instanceof BundleLit) {
          node.bundle.elements.forEach(function(el) { visit(el, false, null); });
        }
        return;
      }

      if (node instanceof BinaryOp) {
        visit(node.left, false, null);
        visit(node.right, false, null);
        return;
      }

      if (node instanceof UnaryOp) {
        visit(node.operand, false, null);
        return;
      }

      if (node instanceof SpindleCall) {
        node.args.forEach(function(arg) { visit(arg, false, null); });
        return;
      }

      if (node instanceof CallExtract) {
        visit(node.call, false, null);
        return;
      }

      if (node instanceof RemapExpr) {
        visit(node.base, false, null);
        node.remappings.forEach(function(r) { visit(r.expr, false, null); });
        return;
      }

      if (node instanceof BundleLit) {
        node.elements.forEach(function(el) { visit(el, false, null); });
        return;
      }

      if (node instanceof ChainExpr) {
        visit(node.base, false, null);
        // Don't descend into pattern blocks - they have their own context
        return;
      }
    }

    visit(expr, false, null);
    return ranges;
  };

  // Compute the size of a range given the default width for open-ended ranges
  LoweringContext.prototype.computeRangeSize = function(rangeInfo, defaultWidth) {
    var range = rangeInfo.range;
    var start = range.start;
    var end = range.end;

    // For ranges inside ExprAccessor with a bundle name, use bundle width for open ends
    var width = defaultWidth;
    if (rangeInfo.inExprAccessor && rangeInfo.bundleName) {
      var info = this.getBundleInfo(rangeInfo.bundleName);
      width = info.width;
    }

    // Resolve open-ended bounds
    if (start === null) start = 0;
    if (end === null) end = width;

    // Handle negative indices
    if (start < 0) start = width + start;
    if (end < 0) end = width + end;

    return { start: start, end: end, size: end - start };
  };

  // Expand an expression by substituting RangeExprs at a given iteration number
  // iterNum is the 0-based iteration (0, 1, 2, ...)
  // defaultWidth is used to resolve open-ended ranges for bare strand accessors
  LoweringContext.prototype.expandRangeExpr = function(expr, iterNum, defaultWidth) {
    var self = this;

    // Helper to compute actual index for a range at this iteration
    function computeIndex(range, bundleName) {
      var start = range.start;
      var end = range.end;

      // Get width for open-ended resolution
      var width = defaultWidth;
      if (bundleName) {
        var info = self.getBundleInfo(bundleName);
        width = info.width;
      }

      // Resolve open-ended bounds
      if (start === null) start = 0;
      if (end === null) end = width;

      // Handle negative indices
      if (start < 0) start = width + start;
      if (end < 0) end = width + end;

      return start + iterNum;
    }

    function substitute(node, bundleContext) {
      if (node instanceof RangeExpr) {
        // Standalone range - replace with bare strand accessor
        var idx = computeIndex(node, bundleContext);
        return new StrandAccess(null, new IndexAccessor(idx));
      }

      if (node instanceof StrandAccess) {
        // Check if accessor is ExprAccessor containing a RangeExpr
        if (node.accessor instanceof ExprAccessor && node.accessor.value instanceof RangeExpr) {
          // Replace ExprAccessor(RangeExpr) with IndexAccessor
          var bundleName = (typeof node.bundle === 'string') ? node.bundle : null;
          var idx2 = computeIndex(node.accessor.value, bundleName);
          return new StrandAccess(node.bundle, new IndexAccessor(idx2));
        }
        // Recursively handle BundleLit bundles and ExprAccessor with non-range content
        var newBundle = node.bundle;
        var newAccessor = node.accessor;
        if (node.bundle instanceof BundleLit) {
          newBundle = new BundleLit(node.bundle.elements.map(function(el) { return substitute(el, null); }));
        }
        if (node.accessor instanceof ExprAccessor) {
          newAccessor = new ExprAccessor(substitute(node.accessor.value, null));
        }
        if (newBundle !== node.bundle || newAccessor !== node.accessor) {
          return new StrandAccess(newBundle, newAccessor);
        }
        return node;
      }

      if (node instanceof BinaryOp) {
        var newLeft = substitute(node.left, null);
        var newRight = substitute(node.right, null);
        if (newLeft !== node.left || newRight !== node.right) {
          return new BinaryOp(newLeft, node.op, newRight);
        }
        return node;
      }

      if (node instanceof UnaryOp) {
        var newOperand = substitute(node.operand, null);
        if (newOperand !== node.operand) {
          return new UnaryOp(node.op, newOperand);
        }
        return node;
      }

      if (node instanceof SpindleCall) {
        var newArgs = node.args.map(function(a) { return substitute(a, null); });
        var changed = newArgs.some(function(a, i) { return a !== node.args[i]; });
        if (changed) {
          return new SpindleCall(node.name, newArgs);
        }
        return node;
      }

      if (node instanceof CallExtract) {
        var newCall = substitute(node.call, null);
        if (newCall !== node.call) {
          return new CallExtract(newCall, node.index);
        }
        return node;
      }

      if (node instanceof RemapExpr) {
        var newBase = substitute(node.base, null);
        var newRemappings = node.remappings.map(function(r) {
          var newExpr = substitute(r.expr, null);
          if (newExpr !== r.expr) {
            return new RemapArg(r.domain, newExpr);
          }
          return r;
        });
        var remapChanged = newRemappings.some(function(r, i) { return r !== node.remappings[i]; });
        if (newBase !== node.base || remapChanged) {
          return new RemapExpr(newBase, newRemappings);
        }
        return node;
      }

      if (node instanceof BundleLit) {
        var newElements = node.elements.map(function(el) { return substitute(el, null); });
        var changed2 = newElements.some(function(e, i) { return e !== node.elements[i]; });
        if (changed2) {
          return new BundleLit(newElements);
        }
        return node;
      }

      // ChainExpr - only substitute in base, not in pattern blocks
      if (node instanceof ChainExpr) {
        var newBase2 = substitute(node.base, null);
        if (newBase2 !== node.base) {
          return new ChainExpr(newBase2, node.patterns);
        }
        return node;
      }

      return node;
    }

    return substitute(expr, null);
  };

  LoweringContext.prototype.lowerChainExpr = function(chain, expectedWidth) {
    var self = this;
    var exprs = this.lowerToStrands(chain.base, this.inferWidth(chain.base));

    chain.patterns.forEach(function(pattern) {
      var prev = exprs;
      exprs = [];

      pattern.outputs.forEach(function(out) {
        match(out,
          inst(PatternOutput, 'expr', _), function(value) {
            // Check for ranges in the expression
            var ranges = self.findRanges(value);

            if (ranges.length === 0) {
              // No ranges - process normally
              var w = self.inferWidth(value);
              if (w === 1) exprs.push(self.lowerExpr(value, prev));
              else exprs.push.apply(exprs, self.lowerToStrands(value, w, prev));
            } else {
              // Has ranges - expand the expression
              // Compute sizes for all ranges
              var sizes = ranges.map(function(r) {
                return self.computeRangeSize(r, prev.length);
              });

              // Verify all ranges have the same size and validate bounds
              var firstSize = sizes[0].size;
              for (var i = 0; i < sizes.length; i++) {
                if (i > 0 && sizes[i].size !== firstSize) {
                  self.error('Range size mismatch: found ranges of size ' + firstSize + ' and ' + sizes[i].size + ' in expression');
                }
                // Validate this range's bounds
                if (sizes[i].start < 0 || sizes[i].size < 0) {
                  self.error('Invalid range ' + ranges[i].range.start + '..' + ranges[i].range.end);
                }
              }

              // Expand the expression for each iteration of the range
              // All ranges have the same size, so iterate that many times
              var rangeSize = sizes[0].size;
              for (var iterNum = 0; iterNum < rangeSize; iterNum++) {
                var expandedExpr = self.expandRangeExpr(value, iterNum, prev.length);
                var w2 = self.inferWidth(expandedExpr);
                if (w2 === 1) exprs.push(self.lowerExpr(expandedExpr, prev));
                else exprs.push.apply(exprs, self.lowerToStrands(expandedExpr, w2, prev));
              }
            }
          },

          _, function(_n) { self.error('Unknown pattern type'); }
        );
      });
    });

    if (exprs.length !== expectedWidth) {
      this.error('Chain produces ' + exprs.length + ' strands, expected ' + expectedWidth);
    }
    return exprs;
  };

  LoweringContext.prototype.buildSelector = function(exprs, irIndex) {
    // Generate select(index, expr0, expr1, ...) builtin
    // Backend will generate proper short-circuit ternary code
    return new IRBuiltin('select', [irIndex].concat(exprs));
  };

  LoweringContext.prototype.substituteInExpr = function(expr, subMap) {
    var self = this;

    if (expr instanceof IRNum) return expr;
    if (expr instanceof IRParam) return expr;

    if (expr instanceof IRIndex) {
      if (expr.indexExpr instanceof IRNum) {
        var key = expr.bundle + '.' + expr.indexExpr.value;
        if (subMap.has(key)) return subMap.get(key);
      }
      return new IRIndex(expr.bundle, self.substituteInExpr(expr.indexExpr, subMap));
    }

    if (expr instanceof IRBinaryOp) {
      return new IRBinaryOp(expr.op, self.substituteInExpr(expr.left, subMap), self.substituteInExpr(expr.right, subMap));
    }

    if (expr instanceof IRUnaryOp) {
      return new IRUnaryOp(expr.op, self.substituteInExpr(expr.operand, subMap));
    }

    if (expr instanceof IRBuiltin) {
      return new IRBuiltin(expr.name, expr.args.map(function(a) { return self.substituteInExpr(a, subMap); }));
    }

    if (expr instanceof IRCall) {
      return new IRCall(expr.spindle, expr.args.map(function(a) { return self.substituteInExpr(a, subMap); }));
    }

    if (expr instanceof IRExtract) {
      return new IRExtract(self.substituteInExpr(expr.call, subMap), expr.index);
    }

    if (expr instanceof IRTexture) {
      return new IRTexture(expr.resourceId, self.substituteInExpr(expr.uExpr, subMap), self.substituteInExpr(expr.vExpr, subMap), expr.channel);
    }

    if (expr instanceof IRCamera) {
      return new IRCamera(self.substituteInExpr(expr.uExpr, subMap), self.substituteInExpr(expr.vExpr, subMap), expr.channel);
    }

    if (expr instanceof IRMicrophone) {
      return new IRMicrophone(self.substituteInExpr(expr.offsetExpr, subMap), expr.channel);
    }

    if (expr instanceof IRRemap) {
      var newSubs = new Map();
      expr.substitutions.forEach(function(v, k) { newSubs.set(k, self.substituteInExpr(v, subMap)); });
      return new IRRemap(self.substituteInExpr(expr.base, subMap), newSubs);
    }

    return expr;
  };

  LoweringContext.prototype.lowerResourceCall = function(name, args, width, subs) {
    var self = this;
    var spec = RESOURCE_BUILTINS[name];
    if (!spec) this.error('Unknown resource builtin: ' + name);
    if (args.length !== spec.argCount) this.error(name + '() expects ' + spec.argCount + ' args, got ' + args.length);
    if (spec.width !== width) this.error(name + '() returns ' + spec.width + ' values, expected ' + width);

    if (name === 'camera') {
      var uExpr = this.lowerExpr(args[0], subs);
      var vExpr = this.lowerExpr(args[1], subs);
      return Array.from({ length: spec.width }, function(_, channel) { return new IRCamera(uExpr, vExpr, channel); });
    }

    if (name === 'microphone') {
      var offsetExpr = this.lowerExpr(args[0], subs);
      return Array.from({ length: spec.width }, function(_, channel) { return new IRMicrophone(offsetExpr, channel); });
    }

    var pathArg = args[0];
    if (!(pathArg instanceof StringLit)) this.error(name + '() first argument must be a string literal');

    var path = pathArg.value;
    var resourceId = this.resourceIndex.get(path);
    if (resourceId === undefined) {
      resourceId = this.resources.length;
      this.resources.push(path);
      this.resourceIndex.set(path, resourceId);
    }

    var uExpr2 = this.lowerExpr(args[1], subs);
    var vExpr2 = this.lowerExpr(args[2], subs);

    return Array.from({ length: spec.width }, function(_, channel) { return new IRTexture(resourceId, uExpr2, vExpr2, channel); });
  };

  LoweringContext.prototype.lowerCall = function(name, args, lower) {
    var irArgs = args.map(lower);
    if (BUILTINS.has(name)) return new IRBuiltin(name, irArgs);

    var info = this.spindleInfo.get(name);
    if (!info) this.error('Unknown spindle: ' + name);
    if (irArgs.length !== info.params.size) {
      this.error('"' + name + '" expects ' + info.params.size + ' args, got ' + irArgs.length);
    }
    return new IRCall(name, irArgs);
  };

  LoweringContext.prototype.lowerStrandAccess = function(expr) {
    var self = this;
    var bundle = expr.bundle;
    var accessor = expr.accessor;

    if (bundle === null) this.error('Bare strand access .' + accessor.value + ' outside pattern');

    if (bundle instanceof BundleLit) {
      var elements = bundle.elements.map(function(e) { return self.lowerExpr(e); });
      return match(accessor,
        inst(IndexAccessor, _), function(idx) {
          var resolved = idx < 0 ? elements.length + idx : idx;
          if (resolved < 0 || resolved >= elements.length) {
            self.error('Index ' + idx + ' out of range for bundle literal');
          }
          return elements[resolved];
        },
        inst(ExprAccessor, _), function(indexExpr) {
          return self.buildSelector(elements, self.lowerExpr(indexExpr));
        },
        inst(NameAccessor, _), function(name) {
          return self.error('Cannot use named access .' + name + ' on bundle literal');
        }
      );
    }

    if (bundle === 'me') {
      var meWidth = Object.keys(ME_STRANDS).length;
      return match(accessor,
        inst(NameAccessor, _), function(name) {
          if (ME_STRANDS[name] === undefined) self.error('Unknown: me.' + name);
          return new IRIndex('me', new IRNum(ME_STRANDS[name]), name);  // Preserve field name
        },
        inst(IndexAccessor, _), function(idx) {
          var resolved = idx < 0 ? meWidth + idx : idx;
          return new IRIndex('me', new IRNum(resolved));
        },
        inst(ExprAccessor, _), function(indexExpr) {
          return new IRIndex('me', self.lowerExpr(indexExpr));
        }
      );
    }

    var info = this.getBundleInfo(bundle);
    return match(accessor,
      inst(NameAccessor, _), function(name) {
        if (!info.strandIndex.has(name)) self.error('Unknown: ' + bundle + '.' + name);
        return new IRIndex(bundle, new IRNum(info.strandIndex.get(name)));
      },
      inst(IndexAccessor, _), function(idx) {
        var resolved = idx < 0 ? info.width + idx : idx;
        if (resolved < 0 || resolved >= info.width) {
          self.error(bundle + '.' + idx + ' out of range');
        }
        return new IRIndex(bundle, new IRNum(resolved));
      },
      inst(ExprAccessor, _), function(indexExpr) {
        return new IRIndex(bundle, self.lowerExpr(indexExpr));
      }
    );
  };

  LoweringContext.prototype.getBundleInfo = function(name) {
    if (this.scope && this.scope.locals && this.scope.locals.has(name)) {
      var local = this.scope.locals.get(name);
      return { strandIndex: local.strandIndex, width: local.strandIndex.size };
    }
    var info = this.bundleInfo.get(name);
    if (!info) this.error('Unknown bundle: ' + name);
    return info;
  };

  LoweringContext.prototype.inferWidth = function(expr) {
    var self = this;
    return match(expr,
      inst(BundleLit, _), function(els) {
        return els.reduce(function(s, e) { return s + self.inferWidth(e); }, 0);
      },
      inst(ChainExpr, _, _), function(base, pats) {
        return pats.length ? pats[pats.length - 1].outputs.length : self.inferWidth(base);
      },
      inst(Identifier, 'me'), function() { return Object.keys(ME_STRANDS).length; },
      inst(Identifier, _), function(name) {
        if (self.scope && self.scope.params && self.scope.params.has(name)) return 1;
        return self.bundleInfo.get(name)?.width ?? self.error('Unknown: ' + name);
      },
      inst(SpindleCall, _, _), function(name, _args) {
        if (RESOURCE_BUILTINS[name]) return RESOURCE_BUILTINS[name].width;
        return self.spindleInfo.get(name)?.width ?? (BUILTINS.has(name) ? 1 : self.error('Unknown: ' + name));
      },
      inst(CallExtract, _, _), function(_call, _idx) { return 1; },
      _, function(_n) { return 1; }
    );
  };

  LoweringContext.prototype.topologicalSort = function() {
    var self = this;
    var strandToDecl = new Map();
    var bundleToDecls = new Map();

    this.declarations.forEach(function(decl, i) {
      decl.strandNames.forEach(function(name) {
        strandToDecl.set(decl.bundle + '.' + name, i);
      });
      var arr = bundleToDecls.get(decl.bundle) || [];
      arr.push(i);
      bundleToDecls.set(decl.bundle, arr);
    });

    var visited = new Set();
    var visiting = new Set();
    var order = [];

    function visit(i) {
      if (visited.has(i)) return;
      if (visiting.has(i)) {
        var d = self.declarations[i];
        self.error('Circular dependency: ' + d.bundle + '.{' + Array.from(d.strandNames) + '}');
      }
      visiting.add(i);

      self.declarations[i].strands.forEach(function(strand) {
        strand.expr.freeVars().forEach(function(ref) {
          if (ref.indexOf('.') !== -1) {
            var dep = strandToDecl.get(ref);
            if (dep !== undefined && dep !== i) visit(dep);
          } else {
            var deps = bundleToDecls.get(ref) || [];
            deps.forEach(function(dep) {
              if (dep !== i) visit(dep);
            });
          }
        });
      });

      visiting.delete(i);
      visited.add(i);
      var d = self.declarations[i];
      order.push({ bundle: d.bundle, strands: Array.from(d.strandNames).map(String) });
    }

    for (var i = 0; i < this.declarations.length; i++) {
      visit(i);
    }
    return order;
  };

  function lower(ast) {
    return new LoweringContext().lowerProgram(ast);
  }

  // ========== Main Compile Function ==========
  function compile(source) {
    var ast = parse(source);
    var ir = lower(ast);
    return JSON.stringify(ir.toJSON());
  }

  // ========== AST to JSON ==========
  function astToJSON(node) {
    if (node === null || node === undefined) return null;
    if (typeof node === 'string' || typeof node === 'number' || typeof node === 'boolean') return node;
    if (Array.isArray(node)) return node.map(astToJSON);

    var type = node.constructor.name;
    var result = { type: type };

    if (node instanceof Program) {
      result.statements = astToJSON(node.statements);
    } else if (node instanceof BundleDecl) {
      result.name = node.name;
      result.outputs = node.outputs;
      result.expr = astToJSON(node.expr);
    } else if (node instanceof SpindleDef) {
      result.name = node.name;
      result.params = node.params;
      result.body = astToJSON(node.body);
    } else if (node instanceof ReturnAssign) {
      result.index = node.index;
      result.expr = astToJSON(node.expr);
    } else if (node instanceof NumberLit) {
      result.value = node.value;
    } else if (node instanceof StringLit) {
      result.value = node.value;
    } else if (node instanceof Identifier) {
      result.name = node.name;
    } else if (node instanceof BundleLit) {
      result.elements = astToJSON(node.elements);
    } else if (node instanceof StrandAccess) {
      result.bundle = astToJSON(node.bundle);
      result.accessor = astToJSON(node.accessor);
    } else if (node instanceof IndexAccessor) {
      result.value = node.value;
    } else if (node instanceof NameAccessor) {
      result.value = node.value;
    } else if (node instanceof ExprAccessor) {
      result.value = astToJSON(node.value);
    } else if (node instanceof BinaryOp) {
      result.op = node.op;
      result.left = astToJSON(node.left);
      result.right = astToJSON(node.right);
    } else if (node instanceof UnaryOp) {
      result.op = node.op;
      result.operand = astToJSON(node.operand);
    } else if (node instanceof SpindleCall) {
      result.name = node.name;
      result.args = astToJSON(node.args);
    } else if (node instanceof CallExtract) {
      result.call = astToJSON(node.call);
      result.index = node.index;
    } else if (node instanceof RemapExpr) {
      result.base = astToJSON(node.base);
      result.remappings = astToJSON(node.remappings);
    } else if (node instanceof RemapArg) {
      result.domain = astToJSON(node.domain);
      result.expr = astToJSON(node.expr);
    } else if (node instanceof ChainExpr) {
      result.base = astToJSON(node.base);
      result.patterns = astToJSON(node.patterns);
    } else if (node instanceof PatternBlock) {
      result.outputs = astToJSON(node.outputs);
    } else if (node instanceof PatternOutput) {
      result.outputType = node.type;
      result.value = astToJSON(node.value);
    } else if (node instanceof RangeExpr) {
      result.start = node.start;
      result.end = node.end;
    }

    return result;
  }

  function parseToAST(source) {
    var ast = parse(source);
    return JSON.stringify(astToJSON(ast));
  }

  // ========== Expose API ==========
  global.WeftCompiler = {
    compile: compile,
    parse: parse,
    parseToAST: parseToAST,
    lower: lower,
    AST: AST,
    IR: IR
  };

})(typeof globalThis !== 'undefined' ? globalThis : (typeof window !== 'undefined' ? window : this));
