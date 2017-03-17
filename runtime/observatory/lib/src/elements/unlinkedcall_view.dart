// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:html';
import 'package:observatory/models.dart' as M;
import 'package:observatory/src/elements/curly_block.dart';
import 'package:observatory/src/elements/helpers/any_ref.dart';
import 'package:observatory/src/elements/helpers/nav_bar.dart';
import 'package:observatory/src/elements/helpers/nav_menu.dart';
import 'package:observatory/src/elements/helpers/rendering_scheduler.dart';
import 'package:observatory/src/elements/helpers/tag.dart';
import 'package:observatory/src/elements/nav/isolate_menu.dart';
import 'package:observatory/src/elements/nav/notify.dart';
import 'package:observatory/src/elements/nav/refresh.dart';
import 'package:observatory/src/elements/nav/top_menu.dart';
import 'package:observatory/src/elements/nav/vm_menu.dart';
import 'package:observatory/src/elements/object_common.dart';
import 'package:observatory/src/elements/view_footer.dart';

class UnlinkedCallViewElement extends HtmlElement implements Renderable {
  static const tag = const Tag<UnlinkedCallViewElement>('unlinkedcall-view',
      dependencies: const [
        CurlyBlockElement.tag,
        NavTopMenuElement.tag,
        NavVMMenuElement.tag,
        NavIsolateMenuElement.tag,
        NavRefreshElement.tag,
        NavNotifyElement.tag,
        ObjectCommonElement.tag,
        ViewFooterElement.tag
      ]);

  RenderingScheduler<UnlinkedCallViewElement> _r;

  Stream<RenderedEvent<UnlinkedCallViewElement>> get onRendered =>
      _r.onRendered;

  M.VM _vm;
  M.IsolateRef _isolate;
  M.EventRepository _events;
  M.NotificationRepository _notifications;
  M.UnlinkedCall _unlinkedcall;
  M.UnlinkedCallRepository _unlinkedcalls;
  M.RetainedSizeRepository _retainedSizes;
  M.ReachableSizeRepository _reachableSizes;
  M.InboundReferencesRepository _references;
  M.RetainingPathRepository _retainingPaths;
  M.InstanceRepository _instances;

  M.VMRef get vm => _vm;
  M.IsolateRef get isolate => _isolate;
  M.NotificationRepository get notifications => _notifications;
  M.UnlinkedCall get unlinkedcall => _unlinkedcall;

  factory UnlinkedCallViewElement(
      M.VM vm,
      M.IsolateRef isolate,
      M.UnlinkedCall unlinkedcall,
      M.EventRepository events,
      M.NotificationRepository notifications,
      M.UnlinkedCallRepository unlinkedcalls,
      M.RetainedSizeRepository retainedSizes,
      M.ReachableSizeRepository reachableSizes,
      M.InboundReferencesRepository references,
      M.RetainingPathRepository retainingPaths,
      M.InstanceRepository instances,
      {RenderingQueue queue}) {
    assert(vm != null);
    assert(isolate != null);
    assert(events != null);
    assert(notifications != null);
    assert(unlinkedcall != null);
    assert(unlinkedcalls != null);
    assert(retainedSizes != null);
    assert(reachableSizes != null);
    assert(references != null);
    assert(retainingPaths != null);
    assert(instances != null);
    UnlinkedCallViewElement e = document.createElement(tag.name);
    e._r = new RenderingScheduler(e, queue: queue);
    e._vm = vm;
    e._isolate = isolate;
    e._events = events;
    e._notifications = notifications;
    e._unlinkedcall = unlinkedcall;
    e._unlinkedcalls = unlinkedcalls;
    e._retainedSizes = retainedSizes;
    e._reachableSizes = reachableSizes;
    e._references = references;
    e._retainingPaths = retainingPaths;
    e._instances = instances;
    return e;
  }

  UnlinkedCallViewElement.created() : super.created();

  @override
  attached() {
    super.attached();
    _r.enable();
  }

  @override
  detached() {
    super.detached();
    _r.disable(notify: true);
    children = [];
  }

  void render() {
    children = [
      navBar([
        new NavTopMenuElement(queue: _r.queue),
        new NavVMMenuElement(_vm, _events, queue: _r.queue),
        new NavIsolateMenuElement(_isolate, _events, queue: _r.queue),
        navMenu('unlinkedcall'),
        new NavRefreshElement(queue: _r.queue)
          ..onRefresh.listen((e) async {
            e.element.disabled = true;
            _unlinkedcall =
                await _unlinkedcalls.get(_isolate, _unlinkedcall.id);
            _r.dirty();
          }),
        new NavNotifyElement(_notifications, queue: _r.queue)
      ]),
      new DivElement()
        ..classes = ['content-centered-big']
        ..children = [
          new HeadingElement.h2()..text = 'UnlinkedCall',
          new HRElement(),
          new ObjectCommonElement(_isolate, _unlinkedcall, _retainedSizes,
              _reachableSizes, _references, _retainingPaths, _instances,
              queue: _r.queue),
          new DivElement()
            ..classes = ['memberList']
            ..children = [
              new DivElement()
                ..classes = ['memberItem']
                ..children = [
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'selector',
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = _unlinkedcall.selector
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = [
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'argumentsDescriptor',
                  new DivElement()
                    ..classes = ['memberName']
                    ..children = [
                      _unlinkedcall.argumentsDescriptor == null
                          ? (new SpanElement()..text = '<none>')
                          : anyRef(_isolate, _unlinkedcall.argumentsDescriptor,
                              _instances,
                              queue: _r.queue)
                    ]
                ]
            ],
          new HRElement(),
          new ViewFooterElement(queue: _r.queue)
        ]
    ];
  }
}