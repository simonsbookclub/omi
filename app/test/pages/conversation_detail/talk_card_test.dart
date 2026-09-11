import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/pages/conversation_detail/widgets/talk_card.dart';
import 'package:omi/providers/us_provider.dart';

/// The card is built from a real payload captured off the live worker
/// (test/fixtures/us_talk.json — the morning of 2026-09-11). A timeline rail
/// is easy to write in a form that only explodes at runtime, so this proves it
/// lays out rather than leaving that to an install on Thor.
Widget _host(UsInfo us) => MaterialApp(
      home: ChangeNotifierProvider<UsProvider>(
        create: (_) => UsProvider(),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SingleChildScrollView(child: TalkCard(us: us)),
        ),
      ),
    );

void main() {
  late Map<String, dynamic> raw;

  setUpAll(() {
    raw = jsonDecode(File('test/fixtures/us_talk.json').readAsStringSync()) as Map<String, dynamic>;
  });

  testWidgets('renders a real talk without a layout failure', (tester) async {
    await tester.pumpWidget(_host(UsInfo.fromJson(raw)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('A REAL TALK'), findsOneWidget);
    expect(find.textContaining('brought it up'), findsWidgets);
  });

  testWidgets('renders nothing when the conversation was not a talk', (tester) async {
    final notTalk = Map<String, dynamic>.from(raw);
    notTalk['analysis'] = Map<String, dynamic>.from(raw['analysis'] as Map<String, dynamic>)..['talk'] = false;
    await tester.pumpWidget(_host(UsInfo.fromJson(notTalk)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('A REAL TALK'), findsNothing);
  });

  testWidgets('survives an analysis with every optional part missing', (tester) async {
    final bare = Map<String, dynamic>.from(raw);
    bare['participation'] = null;
    bare['analysis'] = {
      'talk': true,
      'depth': {'v': 3, 'arc': '', 'threads': [], 'questions': [], 'disclosures': [], 'agreements': []},
    };
    await tester.pumpWidget(_host(UsInfo.fromJson(bare)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('shows nothing for a deep read the server recorded as failed', (tester) async {
    final failed = Map<String, dynamic>.from(raw);
    failed['analysis'] = Map<String, dynamic>.from(raw['analysis'] as Map<String, dynamic>)
      ..['depth'] = {'v': 4, 'failed': true, 'threads': [], 'questions': [], 'disclosures': [], 'agreements': [], 'arc': ''};
    await tester.pumpWidget(_host(UsInfo.fromJson(failed)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('A REAL TALK'), findsNothing);
  });

  testWidgets('a talk on a narrow phone does not overflow', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_host(UsInfo.fromJson(raw)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
