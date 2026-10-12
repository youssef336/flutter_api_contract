import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'models.dart';

/// Reads the keys a hand-written `fromJson` pulls out of its map parameter,
/// and works out, per key, the Dart type the JSON value must have and
/// whether a missing/null value would throw.
class HandWrittenAnalyzer {
  HandWrittenAnalyzer({
    required this.decl,
    required this.lines,
    required this.modelNames,
    required this.enums,
  }) {
    for (final m in decl.body.members) {
      if (m is FieldDeclaration && !m.isStatic) {
        for (final v in m.fields.variables) {
          _fieldTypes[v.name.lexeme] = DartType.parse(
            m.fields.type?.toSource() ?? 'dynamic',
          );
        }
      }
    }
    for (final m in decl.body.members) {
      if (m is! ConstructorDeclaration || m.factoryKeyword != null) continue;
      final positional = <String>[];
      final types = <String, DartType>{};
      for (final param in m.parameters.parameters) {
        final name = param.name?.lexeme;
        if (name == null) continue;
        if (param.isPositional) positional.add(name);
        final explicit = param.type?.toSource();
        final type = explicit != null
            ? DartType.parse(explicit)
            : _fieldTypes[name] ?? const DartType('dynamic');
        types[name] = type;
      }
      _ctors[m.name?.lexeme ?? ''] = (positional, types);
    }
  }

  final ClassDeclaration decl;
  final LineInfo lines;
  final Set<String> modelNames;
  final Map<String, DartEnum> enums;

  final _fieldTypes = <String, DartType>{};

  /// Constructor name ('' = unnamed) -> (positional names, param types).
  final _ctors = <String, (List<String>, Map<String, DartType>)>{};

  String get _className => decl.namePart.typeName.lexeme;

  /// Analyzes the given `fromJson` / `fromMap` members.
  List<FieldRead> analyze(List<ClassMember> members) {
    final merged = <String, FieldRead>{};
    for (final member in members) {
      final (params, body) = switch (member) {
        ConstructorDeclaration() => (member.parameters, member as AstNode),
        MethodDeclaration() => (member.parameters, member as AstNode),
        _ => (null, null),
      };
      final mapParam = params?.parameters.firstOrNull?.name?.lexeme;
      if (mapParam == null || body == null) continue;

      final aliases = <String, List<String>>{mapParam: const []};
      body.accept(_AliasCollector(aliases, mapParam));

      final collector = _ReadCollector(aliases);
      body.accept(collector);
      for (final (expr, path) in collector.reads) {
        for (final read in _toReads(expr, path, body)) {
          final id = read.displayKey;
          final existing = merged[id];
          if (existing == null) {
            merged[id] = read;
          } else {
            existing.nullSafe = existing.nullSafe && read.nullSafe;
            existing.type ??= read.type;
            existing.hasDefault = existing.hasDefault || read.hasDefault;
            existing.enumName ??= read.enumName;
            existing.enumFallback = existing.enumFallback || read.enumFallback;
            existing.customConverter =
                existing.customConverter && read.customConverter;
          }
        }
      }
    }
    return merged.values.toList();
  }

  /// One outermost index chain -> the read it stands for, plus the implicit
  /// "parent must be a map" reads for nested chains (`json['a']['b']`).
  List<FieldRead> _toReads(
    IndexExpression expr,
    List<String> path,
    AstNode body,
  ) {
    final line = lines.getLocation(expr.offset).lineNumber;
    final info = _analyzeRead(expr, body);
    final reads = <FieldRead>[
      FieldRead(
        key: path.first,
        path: path.sublist(1),
        fieldName: info.fieldName,
        type: info.type,
        nullSafe: info.safe,
        hasDefault: info.hasDefault,
        customConverter: info.converter,
        enumFallback: info.enumFallback,
        enumName: info.enumName,
        line: line,
      ),
    ];
    // Every intermediate map in `json['a']['b']` must be non-null unless the
    // access is `?[`.
    Expression? target = _unwrap(expr.target);
    var depth = path.length - 1;
    var nullAware = expr.question != null;
    while (depth >= 1) {
      reads.add(
        FieldRead(
          key: path.first,
          path: path.sublist(1, depth),
          type: const DartType('Map'),
          nullSafe: nullAware,
          line: line,
        ),
      );
      if (target is IndexExpression) {
        nullAware = target.question != null;
        target = _unwrap(target.target);
      } else {
        // Reached an alias: the alias declaration itself is a read.
        break;
      }
      depth--;
    }
    return reads;
  }

  _ReadInfo _analyzeRead(Expression read, AstNode body) {
    final info = _ReadInfo();
    DartType? castType;
    DartType? sinkType;
    var locked = false;
    bool? safe;

    // A sink after a transformation (`.map(...)`) no longer describes the
    // wire value, except to fill in the generics of a raw cast:
    // `(json['x'] as List).map(Item.fromJson).toList()` into `List<Item>`.
    void offer(DartType t) {
      if (!locked) {
        sinkType ??= t;
      } else if (castType != null &&
          castType!.args.isEmpty &&
          castType!.name == t.name) {
        castType = DartType(t.name, nullable: castType!.nullable, args: t.args);
      }
    }

    AstNode node = read;
    loop:
    while (true) {
      final parent = node.parent;
      if (parent == null || identical(node, body)) break;
      switch (parent) {
        case ParenthesizedExpression():
          node = parent;
        case AsExpression() when identical(parent.expression, node):
          final t = DartType.parse(parent.type.toSource());
          if (!locked) castType ??= t;
          if (!t.acceptsNull) safe ??= false;
          node = parent;
        case BinaryExpression() when parent.operator.lexeme == '??':
          if (identical(parent.leftOperand, node)) {
            safe ??= true;
            info.hasDefault = true;
          }
          node = parent;
        case BinaryExpression()
            when const {'==', '!='}.contains(parent.operator.lexeme):
          info.probe = true;
          safe ??= true;
          break loop;
        case BinaryExpression():
          safe ??= false;
          break loop;
        case IsExpression():
          info.probe = true;
          safe ??= true;
          break loop;
        case ConditionalExpression():
          if (identical(parent.condition, node)) {
            info.probe = true;
            safe ??= true;
            break loop;
          }
          node = parent;
        case PrefixExpression() when parent.operator.lexeme == '!':
          safe ??= false;
          break loop;
        case PostfixExpression() when parent.operator.lexeme == '!':
          safe ??= false;
          node = parent;
        case IndexExpression() when identical(parent.index, node):
          // `Status.values.asNameMap()[json['s']]`
          final target = parent.target?.toSource() ?? '';
          final m = RegExp(r'(\w+)\.values\b').firstMatch(target);
          if (m != null) {
            info.enumName = m.group(1);
            info.enumFallback = true;
            sinkType ??= DartType(m.group(1)!);
          }
          safe ??= true;
          break loop;
        case MethodInvocation() when identical(parent.target, node):
          safe ??= _nullTolerantMember(parent.operator, parent.methodName.name);
          locked = true;
          node = parent;
        case PropertyAccess() when identical(parent.target, node):
          safe ??= _nullTolerantMember(
            parent.operator,
            parent.propertyName.name,
          );
          locked = true;
          node = parent;
        case NamedArgument():
          info.fieldName ??= parent.name.lexeme;
          node = parent;
        case ArgumentList():
          final call = parent.parent;
          final sink = _callSink(call, node, info);
          if (sink != null) {
            offer(sink.type);
            if (sink.unsafe) safe ??= false;
            if (sink.acceptsNullFrom != null) {
              safe ??= sink.acceptsNullFrom!.acceptsNull;
            }
            if (sink.stop) break loop;
            locked = true;
            node = call!;
          } else {
            info.converter = castType == null && sinkType == null;
            safe ??= true;
            break loop;
          }
        case ConstructorFieldInitializer():
          final t = _fieldTypes[parent.fieldName.name];
          info.fieldName ??= parent.fieldName.name;
          if (t != null) {
            offer(t);
            safe ??= t.acceptsNull;
          }
          break loop;
        case AssignmentExpression() when identical(parent.rightHandSide, node):
          final lhs = parent.leftHandSide;
          final name = switch (lhs) {
            SimpleIdentifier() => lhs.name,
            PropertyAccess() => lhs.propertyName.name,
            PrefixedIdentifier() => lhs.identifier.name,
            _ => null,
          };
          final t = name == null ? null : _fieldTypes[name];
          if (t != null) {
            info.fieldName ??= name;
            offer(t);
            safe ??= t.acceptsNull;
          }
          break loop;
        case VariableDeclaration():
          final list = parent.parent;
          final typeNode = list is VariableDeclarationList ? list.type : null;
          if (typeNode != null) {
            final t = DartType.parse(typeNode.toSource());
            offer(t);
            safe ??= t.acceptsNull;
          }
          break loop;
        default:
          break loop;
      }
    }

    // `X.values.firstWhere((e) => e.name == json['s'], orElse: ...)`
    for (AstNode? a = read.parent; a != null; a = a.parent) {
      if (a is MethodInvocation) {
        final m = RegExp(
          r'(\w+)\.values$',
        ).firstMatch(a.target?.toSource() ?? '');
        if (m != null) {
          info.enumName ??= m.group(1);
          final name = a.methodName.name;
          final hasOrElse = a.argumentList.arguments.any(
            (x) => x is NamedArgument && x.name.lexeme == 'orElse',
          );
          final fallback =
              hasOrElse || name.endsWith('OrNull') || name == 'where';
          info.enumFallback = info.enumFallback || fallback;
          if (!fallback) safe = false;
          sinkType ??= DartType(m.group(1)!);
          info.probe = false;
          break;
        }
      }
      if (identical(a, body)) break;
    }

    if (_guarded(read, body)) safe = true;
    info.safe = safe ?? true;
    info.type = info.probe ? null : (sinkType ?? castType);
    final enumName = info.enumName;
    if (enumName != null && enums[enumName]?.safeParse == true) {
      info.enumFallback = true;
    }
    return info;
  }

  /// Calls that receive the JSON value directly.
  _Sink? _callSink(AstNode? call, AstNode arg, _ReadInfo info) {
    String? target;
    String? method;
    if (call is MethodInvocation) {
      target = call.target?.toSource();
      method = call.methodName.name;
    } else if (call is InstanceCreationExpression) {
      target = call.constructorName.type.name.lexeme;
      method = call.constructorName.name?.name;
    } else {
      return null;
    }

    // Our own constructor: `Pet(name: json['name'])`.
    final isOwnCtor =
        (target == null && method == _className) ||
        (target == _className && _ctors.containsKey(method)) ||
        (call is InstanceCreationExpression && target == _className);
    if (isOwnCtor) {
      final ctorName = target == null ? '' : (method ?? '');
      final ctor = _ctors[ctorName] ?? _ctors[''];
      if (ctor == null) return null;
      final (positional, types) = ctor;
      String? param;
      if (arg is NamedArgument) {
        param = arg.name.lexeme;
      } else {
        final args = (arg.parent! as ArgumentList).arguments
            .whereType<Expression>()
            .toList();
        final i = args.indexOf(arg as Expression);
        if (i >= 0 && i < positional.length) param = positional[i];
      }
      info.fieldName ??= param;
      final t = param == null ? null : types[param];
      if (t == null) return null;
      return _Sink(type: t, acceptsNullFrom: t, stop: true);
    }

    final targetName = target?.split('.').first;
    if (const {'fromJson', 'fromMap'}.contains(method) && target != null) {
      if (enums.containsKey(target)) {
        info.enumName = target;
        info.enumFallback = enums[target]!.safeParse;
      }
      if (modelNames.contains(target) || enums.containsKey(target)) {
        return _Sink(type: DartType(target), unsafe: true);
      }
      return null;
    }
    if (target == 'DateTime' && (method == 'parse' || method == 'tryParse')) {
      return const _Sink(type: DartType('DateTime'), unsafe: true);
    }
    if (target != null &&
        const {'int', 'double', 'num', 'BigInt'}.contains(target) &&
        (method == 'parse' || method == 'tryParse')) {
      // `int.parse(json['n'])`: the wire value is a string.
      return const _Sink(type: DartType('String'), unsafe: true);
    }
    if (method == 'byName' && target != null && target.endsWith('.values')) {
      info.enumName = targetName;
      info.enumFallback = false;
      return _Sink(type: DartType(targetName!), unsafe: true);
    }
    return null;
  }

  /// Members that can be called on `null` without throwing.
  bool _nullTolerantMember(Token? operator, String name) =>
      operator?.lexeme == '?.' ||
      const {'toString', 'hashCode', 'runtimeType'}.contains(name);

  /// Is [read] inside a branch guarded by a null/containsKey check on the
  /// same key?
  bool _guarded(Expression read, AstNode body) {
    final key = _firstKey(read);
    if (key == null) return false;
    AstNode child = read;
    for (var a = read.parent; a != null; a = a.parent) {
      Expression? condition;
      if (a is ConditionalExpression && !identical(a.condition, child)) {
        condition = a.condition;
      } else if (a is IfStatement && !identical(a.expression, child)) {
        condition = a.expression;
      } else if (a is IfElement && !identical(a.expression, child)) {
        condition = a.expression;
      }
      if (condition != null && _mentionsKey(condition, key)) return true;
      if (identical(a, body)) break;
      child = a;
    }
    return false;
  }

  String? _firstKey(Expression read) {
    final e = _unwrap(read);
    if (e is IndexExpression) {
      final index = e.index;
      return index is SimpleStringLiteral ? index.value : null;
    }
    return null;
  }

  bool _mentionsKey(Expression condition, String key) {
    final finder = _KeyFinder(key);
    condition.accept(finder);
    return finder.found;
  }
}

class _Sink {
  const _Sink({
    required this.type,
    this.unsafe = false,
    this.acceptsNullFrom,
    this.stop = false,
  });
  final DartType type;
  final bool unsafe;
  final DartType? acceptsNullFrom;
  final bool stop;
}

class _ReadInfo {
  DartType? type;
  bool safe = true;
  bool probe = false;
  bool hasDefault = false;
  bool converter = false;
  bool enumFallback = false;
  String? enumName;
  String? fieldName;
}

Expression? _unwrap(Expression? e) {
  var current = e;
  while (true) {
    if (current is ParenthesizedExpression) {
      current = current.expression;
    } else if (current is AsExpression) {
      current = current.expression;
    } else if (current is PostfixExpression && current.operator.lexeme == '!') {
      current = current.operand;
    } else {
      return current;
    }
  }
}

/// The key path of `json['a']['b']` (through parens/casts/aliases).
List<String>? _pathOf(Expression? e, Map<String, List<String>> aliases) {
  final x = _unwrap(e);
  if (x is SimpleIdentifier) return aliases[x.name];
  if (x is IndexExpression) {
    final index = x.index;
    if (index is! SimpleStringLiteral) return null;
    final parent = _pathOf(x.target, aliases);
    return parent == null ? null : [...parent, index.value];
  }
  return null;
}

class _AliasCollector extends RecursiveAstVisitor<void> {
  _AliasCollector(this.aliases, this.mapParam);
  final Map<String, List<String>> aliases;
  final String mapParam;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final path = _pathOf(node.initializer, aliases);
    if (path != null) aliases[node.name.lexeme] = path;
    super.visitVariableDeclaration(node);
  }
}

class _ReadCollector extends RecursiveAstVisitor<void> {
  _ReadCollector(this.aliases);
  final Map<String, List<String>> aliases;
  final reads = <(IndexExpression, List<String>)>[];

  @override
  void visitIndexExpression(IndexExpression node) {
    final path = _pathOf(node, aliases);
    if (path != null && path.isNotEmpty && !_isInnerOfChain(node)) {
      reads.add((node, path));
    }
    super.visitIndexExpression(node);
  }

  /// `json['a']` inside `json['a']['b']` is covered by the outer read.
  bool _isInnerOfChain(IndexExpression node) {
    AstNode current = node;
    var parent = current.parent;
    while (parent is ParenthesizedExpression ||
        parent is AsExpression ||
        (parent is PostfixExpression && parent.operator.lexeme == '!')) {
      current = parent!;
      parent = current.parent;
    }
    return parent is IndexExpression &&
        identical(parent.target, current) &&
        parent.index is SimpleStringLiteral;
  }
}

class _KeyFinder extends RecursiveAstVisitor<void> {
  _KeyFinder(this.key);
  final String key;
  var found = false;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (node.value == key) found = true;
  }
}
