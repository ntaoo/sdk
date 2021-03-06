// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Runs the tests in a batch on the various configurations used on the bots.

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:migration/src/fork.dart';
import 'package:migration/src/log.dart';

const appJit = "--compiler=app_jit";
const dart2js = "--compiler=dart2js";
const dartdevc = "--compiler=dartdevc";
const noCompiler = "--compiler=none";
const precompiler = "--compiler=precompiler";
const analyzer = "--compiler=dart2analyzer";
const dartk = "--compiler=dartk";

const chrome = "--runtime=chrome";
const precompiled = "--runtime=dart_precompiled";
const noRuntime = "--runtime=none";
const vm = "--runtime=vm";
const jsshell = "--runtime=jsshell";

const checked = "--checked";
const dart2jsBatch = "--dart2js-batch";
const fastStartup = "--fast-startup";
const useSdk = "--use-sdk";
const releaseMode = "--mode=release";
const productMode = "--mode=product";
const strong = "--strong";

/// Maps configuration names to a corresponding set of test.dart command line
/// arguments.
///
/// Each configuration name starts with the name of a column on the buildbot
/// waterfall (except for "dartjs-linux" which is just called "dart2js" here)
/// possibly followed by some modifier for a specific bot or annotated step on
/// a bot. The configs here are ordered the same order as the waterfall.
final allConfigs = {
  "vm": [noCompiler, vm],
  "vm-checked": [noCompiler, vm, checked],
  "vm-app": [appJit, vm],
  "vm-app-product": [productMode, appJit, vm],
  "vm-kernel": [dartk, releaseMode, vm],
  "vm-precomp": [precompiler, precompiled],
  "vm-product": [productMode, noCompiler, vm],
  // TODO(rnystrom): Add dart2js-d8-hostchecked, dart2js-d8-minified, or
  // dart2js-jsshell?
  "analyzer": [analyzer, noRuntime, useSdk],
  "analyzer-checked": [analyzer, noRuntime, checked, useSdk],
  "analyzer-strong": [analyzer, noRuntime, checked, strong, useSdk],
  "dart2js": [dart2js, chrome, useSdk, dart2jsBatch],
  "dart2js-jsshell": [dart2js, jsshell, fastStartup, useSdk, dart2jsBatch],
  // TODO(rnystrom): Is it worth running dart2js on Firefox too?
  "dartdevc": [dartdevc, chrome, useSdk, strong],
};

final buildSteps = [
  // The SDK, which also builds the VM.
  ["--mode=release", "create_sdk"],
  // The kernel service.
  ["--mode=release", "kernel-service"],
  // Precompiled runtime for release
  ["--mode=release", "runtime_precompiled"],
  // Product version of the runtime and precompiled runtime.
  ["--mode=product", "runtime", "runtime_precompiled"],
  // Dartdevc and its dependencies.
  ["--mode=release", "dartdevc_test"],
];

Future<Null> main(List<String> arguments) async {
  var argParser = new ArgParser(allowTrailingOptions: true);
  argParser.addFlag("build", help: "Build runtimes before running tests.");
  argParser.addOption("config",
      abbr: "c", allowMultiple: true, help: "Which configurations to run.");
  argParser.addFlag("help");

  var argResults = argParser.parse(arguments);
  if (argResults["help"] as bool) {
    usage(argParser);
    return;
  }

  if (argResults.rest.length != 2) {
    usage(argParser);
    exit(1);
  }

  var build = argResults["build"] as bool;
  var configs = argResults["config"] as List<String>;
  if (configs.isEmpty) configs = allConfigs.keys.toList();

  var tests = scanTests();

  var startIndex = findFork(tests, argResults.rest[0]);
  var endIndex = findFork(tests, argResults.rest[1]);

  if (startIndex == null || endIndex == null) exit(1);

  tests = tests.sublist(startIndex, endIndex + 1);

  if (tests.isEmpty) {
    print("No tests in range.");
    return;
  }

  // Build any needed targets first.
  if (build) {
    for (var steps in buildSteps) {
      var command = "tools/build.py ${steps.join(' ')}";
      print("Building ${bold(command)}:");
      var exitCode = await run("tools/build.py", steps);
      if (exitCode != 0) {
        print(red("Build failed: $command"));
      }
    }
  }

  // Splits the tests into selectors and patterns.
  var selectors = <String, List<String>>{};
  for (var test in tests) {
    var parts = p.split(p.withoutExtension(test.twoPath));
    var selector = parts[0];
    var path = parts.skip(1).join("/");
    selectors.putIfAbsent(selector, () => []).add(path);
  }

  var failed = <String>[];
  var passed = <String>[];
  for (var name in configs) {
    var configArgs = allConfigs[name];
    print("${bold(name)} ${configArgs.join(' ')}:");

    var args = ["--progress=diff"];

    args.addAll(configArgs);

    if (!args.any((arg) => arg.startsWith("--mode"))) {
      args.add("--mode=release");
    }

    selectors.forEach((selector, paths) {
      args.add("$selector/${paths.join('|')}");
    });

    var exitCode = await run("tools/test.py", args);
    if (exitCode != 0) {
      print(red("Configuration failed: $name"));
      failed.add(name);
    } else {
      passed.add(name);
    }
  }

  if (failed.length == 0) {
    var s = passed.length == 1 ? "" : "s";
    print("${green('PASSED')} all ${bold(passed.length)} configuration$s!");
  } else {
    if (passed.length > 0) {
      var s = passed == 1 ? "" : "s";
      print("${green('PASSED')} ${bold(passed.length)} configuration$s:");
      for (var config in passed) {
        print("- ${bold(config)}");
      }
    }

    var s = failed == 1 ? "" : "s";
    print("${red("FAILED")} ${bold(failed.length)} configuration$s:");
    for (var config in failed) {
      print("- ${bold(config)}");
    }
  }
}

void usage(ArgParser parser) {
  print("Usage: dart run_tests.dart [--build] [--configs=...] "
      "<first file> <last file>");
  print("\n");
  print("Example:");
  print("\n");
  print("    \$ dart run_tests.dart map_to_string queue");
  print("\n");
  print(parser.usage);
}

Future<int> run(String executable, List<String> arguments) async {
  var process = await Process.start(executable, arguments);
  process.stdout.listen((bytes) {
    stdout.add(bytes);
  });

  process.stderr.listen((bytes) {
    stderr.add(bytes);
  });

  return await process.exitCode;
}
