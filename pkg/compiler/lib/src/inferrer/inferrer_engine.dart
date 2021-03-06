// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart' as ir;

import '../common.dart';
import '../common/names.dart';
import '../compiler.dart';
import '../common_elements.dart';
import '../elements/elements.dart'
    show
        ClassElement,
        ConstructorElement,
        Elements,
        MemberElement,
        ParameterElement;
import '../elements/entities.dart';
import '../elements/names.dart';
import '../js_backend/annotations.dart';
import '../js_backend/js_backend.dart';
import '../native/behavior.dart' as native;
import '../types/types.dart';
import '../universe/call_structure.dart';
import '../universe/selector.dart';
import '../universe/side_effects.dart';
import '../world.dart';
import 'debug.dart' as debug;
import 'locals_handler.dart';
import 'list_tracer.dart';
import 'map_tracer.dart';
import 'builder.dart';
import 'type_graph_inferrer.dart';
import 'type_graph_nodes.dart';
import 'type_system.dart';

/// An inferencing engine that computes a call graph of [TypeInformation] nodes
/// by visiting the AST of the application, and then does the inferencing on the
/// graph.
abstract class InferrerEngine<T> {
  /// A set of selector names that [List] implements, that we know return their
  /// element type.
  final Set<Selector> returnsListElementTypeSet =
      new Set<Selector>.from(<Selector>[
    new Selector.getter(const PublicName('first')),
    new Selector.getter(const PublicName('last')),
    new Selector.getter(const PublicName('single')),
    new Selector.call(const PublicName('singleWhere'), CallStructure.ONE_ARG),
    new Selector.call(const PublicName('elementAt'), CallStructure.ONE_ARG),
    new Selector.index(),
    new Selector.call(const PublicName('removeAt'), CallStructure.ONE_ARG),
    new Selector.call(const PublicName('removeLast'), CallStructure.NO_ARGS)
  ]);

  Compiler get compiler;
  ClosedWorld get closedWorld;
  ClosedWorldRefiner get closedWorldRefiner;
  JavaScriptBackend get backend => compiler.backend;
  OptimizerHintsForTests get optimizerHints => backend.optimizerHints;
  DiagnosticReporter get reporter => compiler.reporter;
  CommonMasks get commonMasks => closedWorld.commonMasks;
  CommonElements get commonElements => closedWorld.commonElements;

  TypeSystem<T> get types;
  Map<T, TypeInformation> get concreteTypes;

  /// Parallel structure for concreteTypes.
  // TODO(efortuna): Remove concreteTypes and/or parameterize InferrerEngine by
  // ir.Node or ast.Node type. Then remove this in favor of `concreteTypes`.
  Map<ir.Node, TypeInformation> get concreteKernelTypes;

  FunctionEntity get mainElement;

  void runOverAllElements();

  void analyze(MemberEntity member, T node, ArgumentsTypes arguments);
  void analyzeListAndEnqueue(ListTypeInformation info);
  void analyzeMapAndEnqueue(MapTypeInformation info);

  /// Notifies to the inferrer that [analyzedElement] can have return type
  /// [newType]. [currentType] is the type the [ElementGraphBuilder] currently
  /// found.
  ///
  /// Returns the new type for [analyzedElement].
  TypeInformation addReturnTypeForMethod(
      FunctionEntity element, TypeInformation unused, TypeInformation newType);

  /// Applies [f] to all elements in the universe that match [selector] and
  /// [mask]. If [f] returns false, aborts the iteration.
  void forEachElementMatching(
      Selector selector, TypeMask mask, bool f(MemberEntity element));

  /// Returns the [TypeInformation] node for the default value of a parameter.
  /// If this is queried before it is set by [setDefaultTypeOfParameter], a
  /// [PlaceholderTypeInformation] is returned, which will later be replaced
  /// by the actual node when [setDefaultTypeOfParameter] is called.
  ///
  /// Invariant: After graph construction, no [PlaceholderTypeInformation] nodes
  /// should be present and a default type for each parameter should exist.
  TypeInformation getDefaultTypeOfParameter(Local parameter);

  /// This helper breaks abstractions but is currently required to work around
  /// the wrong modeling of default values of optional parameters of
  /// synthetic constructors.
  ///
  /// TODO(johnniwinther): Remove once default values of synthetic parameters
  /// are fixed.
  bool hasAlreadyComputedTypeOfParameterDefault(Local parameter);

  /// Sets the type of a parameter's default value to [type]. If the global
  /// mapping in [defaultTypeOfParameter] already contains a type, it must be
  /// a [PlaceholderTypeInformation], which will be replaced. All its uses are
  /// updated.
  void setDefaultTypeOfParameter(Local parameter, TypeInformation type,
      {bool isInstanceMember});

  Iterable<MemberEntity> getCallersOf(MemberEntity element);

  // TODO(johnniwinther): Make this private again.
  GlobalTypeInferenceElementData dataOfMember(MemberEntity element);

  GlobalTypeInferenceElementData lookupDataOfMember(MemberEntity element);

  bool checkIfExposesThis(ConstructorEntity element);

  void recordExposesThis(ConstructorEntity element, bool exposesThis);

  /// Records that the return type [element] is of type [type].
  void recordReturnType(FunctionEntity element, TypeInformation type);

  /// Records that [element] is of type [type].
  void recordTypeOfField(FieldEntity element, TypeInformation type);

  /// Registers a call to await with an expression of type [argumentType] as
  /// argument.
  TypeInformation registerAwait(T node, TypeInformation argument);

  /// Registers a call to yield with an expression of type [argumentType] as
  /// argument.
  TypeInformation registerYield(T node, TypeInformation argument);

  /// Registers that [caller] calls [closure] with [arguments].
  ///
  /// [sideEffects] will be updated to incorporate the potential callees' side
  /// effects.
  ///
  /// [inLoop] tells whether the call happens in a loop.
  TypeInformation registerCalledClosure(
      T node,
      Selector selector,
      TypeMask mask,
      TypeInformation closure,
      MemberEntity caller,
      ArgumentsTypes arguments,
      SideEffects sideEffects,
      bool inLoop);

  /// Registers that [caller] calls [callee] at location [node], with
  /// [selector], and [arguments]. Note that [selector] is null for forwarding
  /// constructors.
  ///
  /// [sideEffects] will be updated to incorporate [callee]'s side effects.
  ///
  /// [inLoop] tells whether the call happens in a loop.
  TypeInformation registerCalledMember(
      Spannable node,
      Selector selector,
      TypeMask mask,
      MemberEntity caller,
      MemberEntity callee,
      ArgumentsTypes arguments,
      SideEffects sideEffects,
      bool inLoop);

  /// Registers that [caller] calls [selector] with [receiverType] as receiver,
  /// and [arguments].
  ///
  /// [sideEffects] will be updated to incorporate the potential callees' side
  /// effects.
  ///
  /// [inLoop] tells whether the call happens in a loop.
  TypeInformation registerCalledSelector(
      CallType callType,
      T node,
      Selector selector,
      TypeMask mask,
      TypeInformation receiverType,
      MemberEntity caller,
      ArgumentsTypes arguments,
      SideEffects sideEffects,
      bool inLoop,
      bool isConditional);

  /// Update the assignments to parameters in the graph. [remove] tells whether
  /// assignments must be added or removed. If [init] is false, parameters are
  /// added to the work queue.
  void updateParameterAssignments(TypeInformation caller, MemberEntity callee,
      ArgumentsTypes arguments, Selector selector, TypeMask mask,
      {bool remove, bool addToQueue: true});

  void updateSelectorInMember(MemberEntity owner, CallType callType, T node,
      Selector selector, TypeMask mask);

  /// Returns the return type of [element].
  TypeInformation returnTypeOfMember(MemberEntity element);

  /// Returns the type of [element] when being called with [selector].
  TypeInformation typeOfMemberWithSelector(
      MemberEntity element, Selector selector);

  /// Returns the type of [element].
  TypeInformation typeOfMember(MemberEntity element);

  /// Returns the type of [element].
  TypeInformation typeOfParameter(Local element);

  /// Returns the type for [nativeBehavior]. See documentation on
  /// [native.NativeBehavior].
  TypeInformation typeOfNativeBehavior(native.NativeBehavior nativeBehavior);

  bool returnsListElementType(Selector selector, TypeMask mask);

  bool returnsMapValueType(Selector selector, TypeMask mask);

  void clear();
}

abstract class InferrerEngineImpl<T> extends InferrerEngine<T> {
  final Map<Local, TypeInformation> defaultTypeOfParameter =
      new Map<Local, TypeInformation>();
  final WorkQueue workQueue = new WorkQueue();
  final FunctionEntity mainElement;
  final Set<MemberEntity> analyzedElements = new Set<MemberEntity>();

  /// The maximum number of times we allow a node in the graph to
  /// change types. If a node reaches that limit, we give up
  /// inferencing on it and give it the dynamic type.
  final int MAX_CHANGE_COUNT = 6;

  int overallRefineCount = 0;
  int addedInGraph = 0;

  final Compiler compiler;

  /// The [ClosedWorld] on which inference reasoning is based.
  final ClosedWorld closedWorld;

  final ClosedWorldRefiner closedWorldRefiner;
  final TypeSystem<T> types;
  final Map<T, TypeInformation> concreteTypes = new Map<T, TypeInformation>();

  final Map<ir.Node, TypeInformation> concreteKernelTypes =
      new Map<ir.Node, TypeInformation>();
  final Set<ConstructorEntity> generativeConstructorsExposingThis =
      new Set<ConstructorEntity>();

  /// Data computed internally within elements, like the type-mask of a send a
  /// list allocation, or a for-in loop.
  final Map<MemberEntity, GlobalTypeInferenceElementData> _memberData =
      new Map<MemberEntity, GlobalTypeInferenceElementData>();

  InferrerEngineImpl(
      this.compiler,
      ClosedWorld closedWorld,
      this.closedWorldRefiner,
      this.mainElement,
      TypeSystemStrategy<T> typeSystemStrategy)
      : this.types = new TypeSystem<T>(closedWorld, typeSystemStrategy),
        this.closedWorld = closedWorld;

  void forEachElementMatching(
      Selector selector, TypeMask mask, bool f(MemberEntity element)) {
    Iterable<MemberEntity> elements = closedWorld.locateMembers(selector, mask);
    for (MemberEntity e in elements) {
      if (!f(e)) return;
    }
  }

  GlobalTypeInferenceElementData<T> createElementData();

  // TODO(johnniwinther): Make this private again.
  GlobalTypeInferenceElementData<T> dataOfMember(MemberEntity element) =>
      _memberData.putIfAbsent(element, createElementData);

  GlobalTypeInferenceElementData<T> lookupDataOfMember(MemberEntity element) =>
      _memberData[element];

  /**
   * Update [sideEffects] with the side effects of [callee] being
   * called with [selector].
   */
  void updateSideEffects(
      SideEffects sideEffects, Selector selector, MemberEntity callee) {
    assert(!(callee is MemberElement && !callee.isDeclaration));
    if (callee.isField) {
      if (callee.isInstanceMember) {
        if (selector.isSetter) {
          sideEffects.setChangesInstanceProperty();
        } else if (selector.isGetter) {
          sideEffects.setDependsOnInstancePropertyStore();
        } else {
          sideEffects.setAllSideEffects();
          sideEffects.setDependsOnSomething();
        }
      } else {
        if (selector.isSetter) {
          sideEffects.setChangesStaticProperty();
        } else if (selector.isGetter) {
          sideEffects.setDependsOnStaticPropertyStore();
        } else {
          sideEffects.setAllSideEffects();
          sideEffects.setDependsOnSomething();
        }
      }
    } else if (callee.isGetter && !selector.isGetter) {
      sideEffects.setAllSideEffects();
      sideEffects.setDependsOnSomething();
    } else {
      sideEffects.add(closedWorldRefiner.getCurrentlyKnownSideEffects(callee));
    }
  }

  TypeInformation typeOfNativeBehavior(native.NativeBehavior nativeBehavior) {
    if (nativeBehavior == null) return types.dynamicType;
    List typesReturned = nativeBehavior.typesReturned;
    if (typesReturned.isEmpty) return types.dynamicType;
    TypeInformation returnType;
    for (var type in typesReturned) {
      TypeInformation mappedType;
      if (type == native.SpecialType.JsObject) {
        mappedType = types.nonNullExact(commonElements.objectClass);
      } else if (type == commonElements.stringType) {
        mappedType = types.stringType;
      } else if (type == commonElements.intType) {
        mappedType = types.intType;
      } else if (type == commonElements.numType ||
          type == commonElements.doubleType) {
        // Note: the backend double class is specifically for non-integer
        // doubles, and a native behavior returning 'double' does not guarantee
        // a non-integer return type, so we return the number type for those.
        mappedType = types.numType;
      } else if (type == commonElements.boolType) {
        mappedType = types.boolType;
      } else if (type == commonElements.nullType) {
        mappedType = types.nullType;
      } else if (type.isVoid) {
        mappedType = types.nullType;
      } else if (type.isDynamic) {
        return types.dynamicType;
      } else {
        mappedType = types.nonNullSubtype(type.element);
      }
      returnType = types.computeLUB(returnType, mappedType);
      if (returnType == types.dynamicType) {
        break;
      }
    }
    return returnType;
  }

  void updateSelectorInMember(MemberEntity owner, CallType callType, T node,
      Selector selector, TypeMask mask) {
    GlobalTypeInferenceElementData data = dataOfMember(owner);
    assert(validCallType(callType, node));
    switch (callType) {
      case CallType.complex:
        if (selector.isSetter || selector.isIndexSet) {
          data.setTypeMask(node, mask);
        } else if (selector.isGetter || selector.isIndex) {
          data.setGetterTypeMaskInComplexSendSet(node, mask);
        } else {
          assert(selector.isOperator);
          data.setOperatorTypeMaskInComplexSendSet(node, mask);
        }
        break;
      case CallType.access:
        data.setTypeMask(node, mask);
        break;
      case CallType.forIn:
        if (selector == Selectors.iterator) {
          data.setIteratorTypeMask(node, mask);
        } else if (selector == Selectors.current) {
          data.setCurrentTypeMask(node, mask);
        } else {
          assert(selector == Selectors.moveNext);
          data.setMoveNextTypeMask(node, mask);
        }
        break;
    }
  }

  bool checkIfExposesThis(ConstructorEntity element) {
    assert(!(element is ConstructorElement && !element.isDeclaration));
    return generativeConstructorsExposingThis.contains(element);
  }

  void recordExposesThis(ConstructorEntity element, bool exposesThis) {
    assert(!(element is ConstructorElement && !element.isDeclaration));
    if (exposesThis) {
      generativeConstructorsExposingThis.add(element);
    }
  }

  bool returnsListElementType(Selector selector, TypeMask mask) {
    return mask != null &&
        mask.isContainer &&
        returnsListElementTypeSet.contains(selector);
  }

  bool returnsMapValueType(Selector selector, TypeMask mask) {
    return mask != null && mask.isMap && selector.isIndex;
  }

  void analyzeListAndEnqueue(ListTypeInformation info) {
    if (info.analyzed) return;
    info.analyzed = true;

    ListTracerVisitor tracer = new ListTracerVisitor(info, this);
    bool succeeded = tracer.run();
    if (!succeeded) return;

    info.bailedOut = false;
    info.elementType.inferred = true;
    TypeMask fixedListType = commonMasks.fixedListType;
    if (info.originalType.forwardTo == fixedListType) {
      info.checksGrowable = tracer.callsGrowableMethod;
    }
    tracer.assignments.forEach(info.elementType.addAssignment);
    // Enqueue the list for later refinement
    workQueue.add(info);
    workQueue.add(info.elementType);
  }

  void analyzeMapAndEnqueue(MapTypeInformation info) {
    if (info.analyzed) return;
    info.analyzed = true;
    MapTracerVisitor tracer = new MapTracerVisitor(info, this);

    bool succeeded = tracer.run();
    if (!succeeded) return;

    info.bailedOut = false;
    for (int i = 0; i < tracer.keyAssignments.length; ++i) {
      TypeInformation newType = info.addEntryAssignment(
          tracer.keyAssignments[i], tracer.valueAssignments[i]);
      if (newType != null) workQueue.add(newType);
    }
    for (TypeInformation map in tracer.mapAssignments) {
      workQueue.addAll(info.addMapAssignment(map));
    }

    info.markAsInferred();
    workQueue.add(info.keyType);
    workQueue.add(info.valueType);
    workQueue.addAll(info.typeInfoMap.values);
    workQueue.add(info);
  }

  void runOverAllElements();

  void analyze(MemberEntity element, T body, ArgumentsTypes arguments);

  void processLoopInformation() {
    types.allocatedCalls.forEach((dynamic info) {
      if (!info.inLoop) return;
      if (info is StaticCallSiteTypeInformation) {
        MemberEntity member = info.calledElement;
        closedWorldRefiner.addFunctionCalledInLoop(member);
      } else if (info.mask != null && !info.mask.containsAll(closedWorld)) {
        // For instance methods, we only register a selector called in a
        // loop if it is a typed selector, to avoid marking too many
        // methods as being called from within a loop. This cuts down
        // on the code bloat.
        info.targets.forEach((MemberEntity element) {
          closedWorldRefiner.addFunctionCalledInLoop(element);
        });
      }
    });
  }

  void refine() {
    while (!workQueue.isEmpty) {
      if (compiler.shouldPrintProgress) {
        reporter.log('Inferred $overallRefineCount types.');
        compiler.progress.reset();
      }
      TypeInformation info = workQueue.remove();
      TypeMask oldType = info.type;
      TypeMask newType = info.refine(this);
      // Check that refinement has not accidentally changed the type.
      assert(oldType == info.type);
      if (info.abandonInferencing) info.doNotEnqueue = true;
      if ((info.type = newType) != oldType) {
        overallRefineCount++;
        info.refineCount++;
        if (info.refineCount > MAX_CHANGE_COUNT) {
          if (debug.ANOMALY_WARN) {
            print("ANOMALY WARNING: max refinement reached for $info");
          }
          info.giveUp(this);
          info.type = info.refine(this);
          info.doNotEnqueue = true;
        }
        workQueue.addAll(info.users);
        if (info.hasStableType(this)) {
          info.stabilize(this);
        }
      }
    }
  }

  void buildWorkQueue() {
    workQueue.addAll(types.orderedTypeInformations);
    workQueue.addAll(types.allocatedTypes);
    workQueue.addAll(types.allocatedClosures);
    workQueue.addAll(types.allocatedCalls);
  }

  void updateParameterAssignments(TypeInformation caller, MemberEntity callee,
      ArgumentsTypes arguments, Selector selector, TypeMask mask,
      {bool remove, bool addToQueue: true});

  void setDefaultTypeOfParameter(Local parameter, TypeInformation type,
      {bool isInstanceMember}) {
    assert(!(parameter is ParameterElement && !parameter.isImplementation));
    TypeInformation existing = defaultTypeOfParameter[parameter];
    defaultTypeOfParameter[parameter] = type;
    TypeInformation info = types.getInferredTypeOfParameter(parameter);
    if (existing != null && existing is PlaceholderTypeInformation) {
      // Replace references to [existing] to use [type] instead.
      if (isInstanceMember) {
        ParameterAssignments assignments = info.assignments;
        assignments.replace(existing, type);
      } else {
        List<TypeInformation> assignments = info.assignments;
        for (int i = 0; i < assignments.length; i++) {
          if (assignments[i] == existing) {
            assignments[i] = type;
          }
        }
      }
      // Also forward all users.
      type.addUsersOf(existing);
    } else {
      assert(existing == null);
    }
  }

  TypeInformation getDefaultTypeOfParameter(Local parameter) {
    assert(!(parameter is ParameterElement && !parameter.isImplementation));
    return defaultTypeOfParameter.putIfAbsent(parameter, () {
      return new PlaceholderTypeInformation(types.currentMember);
    });
  }

  bool hasAlreadyComputedTypeOfParameterDefault(Local parameter) {
    assert(!(parameter is ParameterElement && !parameter.isImplementation));
    TypeInformation seen = defaultTypeOfParameter[parameter];
    return (seen != null && seen is! PlaceholderTypeInformation);
  }

  TypeInformation typeOfParameter(Local element) {
    return types.getInferredTypeOfParameter(element);
  }

  TypeInformation typeOfMember(MemberEntity element) {
    if (element is FunctionEntity) return types.functionType;
    return types.getInferredTypeOfMember(element);
  }

  TypeInformation returnTypeOfMember(MemberEntity element) {
    if (element is! FunctionEntity) return types.dynamicType;
    return types.getInferredTypeOfMember(element);
  }

  void recordTypeOfField(FieldEntity element, TypeInformation type) {
    types.getInferredTypeOfMember(element).addAssignment(type);
  }

  void recordReturnType(FunctionEntity element, TypeInformation type) {
    TypeInformation info = types.getInferredTypeOfMember(element);
    if (element.name == '==') {
      // Even if x.== doesn't return a bool, 'x == null' evaluates to 'false'.
      info.addAssignment(types.boolType);
    }
    // TODO(ngeoffray): Clean up. We do these checks because
    // [SimpleTypesInferrer] deals with two different inferrers.
    if (type == null) return;
    if (info.assignments.isEmpty) info.addAssignment(type);
  }

  TypeInformation addReturnTypeForMethod(
      FunctionEntity element, TypeInformation unused, TypeInformation newType) {
    TypeInformation type = types.getInferredTypeOfMember(element);
    // TODO(ngeoffray): Clean up. We do this check because
    // [SimpleTypesInferrer] deals with two different inferrers.
    if (element is ConstructorEntity && element.isGenerativeConstructor) {
      return type;
    }
    type.addAssignment(newType);
    return type;
  }

  TypeInformation registerCalledMember(
      Spannable node,
      Selector selector,
      TypeMask mask,
      MemberEntity caller,
      MemberEntity callee,
      ArgumentsTypes arguments,
      SideEffects sideEffects,
      bool inLoop) {
    CallSiteTypeInformation info = new StaticCallSiteTypeInformation(
        types.currentMember,
        node,
        caller,
        callee,
        selector,
        mask,
        arguments,
        inLoop);
    // If this class has a 'call' method then we have essentially created a
    // closure here. Register it as such so that it is traced.
    // Note: we exclude factory constructors because they don't always create an
    // instance of the type. They are static methods that delegate to some other
    // generative constructor to do the actual creation of the object.
    if (selector != null &&
        selector.isCall &&
        callee is ConstructorEntity &&
        callee.isGenerativeConstructor) {
      ClassElement cls = callee.enclosingClass;
      if (cls.callType != null) {
        types.allocatedClosures.add(info);
      }
    }
    info.addToGraph(this);
    types.allocatedCalls.add(info);
    updateSideEffects(sideEffects, selector, callee);
    return info;
  }

  TypeInformation registerCalledSelector(
      CallType callType,
      T node,
      Selector selector,
      TypeMask mask,
      TypeInformation receiverType,
      MemberEntity caller,
      ArgumentsTypes arguments,
      SideEffects sideEffects,
      bool inLoop,
      bool isConditional) {
    if (selector.isClosureCall) {
      return registerCalledClosure(node, selector, mask, receiverType, caller,
          arguments, sideEffects, inLoop);
    }

    closedWorld.locateMembers(selector, mask).forEach((callee) {
      updateSideEffects(sideEffects, selector, callee);
    });

    CallSiteTypeInformation info = new DynamicCallSiteTypeInformation(
        types.currentMember,
        callType,
        node,
        caller,
        selector,
        mask,
        receiverType,
        arguments,
        inLoop,
        isConditional);

    info.addToGraph(this);
    types.allocatedCalls.add(info);
    return info;
  }

  TypeInformation registerAwait(T node, TypeInformation argument) {
    AwaitTypeInformation info =
        new AwaitTypeInformation<T>(types.currentMember, node);
    info.addAssignment(argument);
    types.allocatedTypes.add(info);
    return info;
  }

  TypeInformation registerYield(T node, TypeInformation argument) {
    YieldTypeInformation info =
        new YieldTypeInformation<T>(types.currentMember, node);
    info.addAssignment(argument);
    types.allocatedTypes.add(info);
    return info;
  }

  TypeInformation registerCalledClosure(
      T node,
      Selector selector,
      TypeMask mask,
      TypeInformation closure,
      MemberEntity caller,
      ArgumentsTypes arguments,
      SideEffects sideEffects,
      bool inLoop) {
    sideEffects.setDependsOnSomething();
    sideEffects.setAllSideEffects();
    CallSiteTypeInformation info = new ClosureCallSiteTypeInformation(
        types.currentMember,
        node,
        caller,
        selector,
        mask,
        closure,
        arguments,
        inLoop);
    info.addToGraph(this);
    types.allocatedCalls.add(info);
    return info;
  }

  void clear() {
    void cleanup(TypeInformation info) => info.cleanup();

    types.allocatedCalls.forEach(cleanup);
    types.allocatedCalls.clear();

    defaultTypeOfParameter.clear();

    types.parameterTypeInformations.values.forEach(cleanup);
    types.memberTypeInformations.values.forEach(cleanup);

    types.allocatedTypes.forEach(cleanup);
    types.allocatedTypes.clear();

    types.concreteTypes.clear();

    types.allocatedClosures.forEach(cleanup);
    types.allocatedClosures.clear();

    analyzedElements.clear();
    generativeConstructorsExposingThis.clear();

    types.allocatedMaps.values.forEach(cleanup);
    types.allocatedLists.values.forEach(cleanup);
  }

  Iterable<MemberEntity> getCallersOf(MemberEntity element) {
    if (compiler.disableTypeInference) {
      throw new UnsupportedError(
          "Cannot query the type inferrer when type inference is disabled.");
    }
    MemberTypeInformation info = types.getInferredTypeOfMember(element);
    return info.callers;
  }

  TypeInformation typeOfMemberWithSelector(
      covariant MemberElement element, Selector selector) {
    if (element.name == Identifiers.noSuchMethod_ &&
        selector.name != element.name) {
      // An invocation can resolve to a [noSuchMethod], in which case
      // we get the return type of [noSuchMethod].
      return returnTypeOfMember(element);
    } else if (selector.isGetter) {
      if (element.isFunction) {
        // [functionType] is null if the inferrer did not run.
        return types.functionType == null
            ? types.dynamicType
            : types.functionType;
      } else if (element.isField) {
        return typeOfMember(element);
      } else if (Elements.isUnresolved(element)) {
        return types.dynamicType;
      } else {
        assert(element.isGetter);
        return returnTypeOfMember(element);
      }
    } else if (element.isGetter || element.isField) {
      assert(selector.isCall || selector.isSetter);
      return types.dynamicType;
    } else {
      return returnTypeOfMember(element);
    }
  }
}
