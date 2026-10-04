import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/app.dart';
import 'package:spoonfull_flutter_app/data/models/auth_token.dart';
import 'package:spoonfull_flutter_app/core/utils/time_utils.dart';

import '../helpers/test_services.dart';

Future<void> _pumpApp(WidgetTester tester, TestEnv env) async {
  useDesignViewport(tester);
  await tester.pumpWidget(SpoonfullApp(services: env.services));
  await tester.pumpAndSettle();
}

/// 結束前卸載畫面並停止同步計時器。
Future<void> _teardown(WidgetTester tester, TestEnv env) async {
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

Future<void> _enterOnKeypad(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.byKey(Key('key-$d')));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('key-confirm')));
  await tester.pumpAndSettle();
}

Future<TestEnv> _pairedEnv() async {
  final env = await createTestEnv(
    prefs: {...configuredPrefs, 'device_config.paired': true},
  );
  await env.tokens.write(
    AuthToken(deviceToken: 'mock-token', tokenAcquiredAt: nowUnix()),
  );
  return env;
}

void main() {
  testWidgets('unpaired: settings → pairing → start enabled', (tester) async {
    final env = await createTestEnv();
    await _pumpApp(tester, env);

    // 未設定:顯示提示對話框,開始使用停用
    expect(find.byKey(const Key('welcome-hint')), findsOneWidget);
    final start = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('start-button')),
        matching: find.byType(InkWell),
      ),
    );
    expect(start.onTap, isNull);

    // 設定頁:空白儲存 → 紅色必填提示
    debugPrint("STEP 1");
    await tester.tap(find.byKey(const Key('welcome-settings')));
    debugPrint("STEP 2");
    await tester.pumpAndSettle();
    debugPrint("STEP 3");
    await tester.tap(find.byKey(const Key('save-settings')));
    debugPrint("STEP 4");
    await tester.pumpAndSettle();
    expect(find.text('*伺服器位址'), findsOneWidget);
    expect(find.text('*埠'), findsOneWidget);
    expect(find.text('*場域'), findsOneWidget);

    // 填寫設定;埠使用數字鍵盤
    debugPrint("STEP 5");
    await tester.enterText(find.byKey(const Key('field-host')), '10.0.0.5');
    debugPrint("STEP 6");
    await tester.enterText(find.byKey(const Key('field-place')), 'demo');
    debugPrint("STEP 7");
    await tester.tap(find.byKey(const Key('field-port')));
    debugPrint("STEP 8");
    await tester.pumpAndSettle();
    await _enterOnKeypad(tester, '8080');
    expect(find.text('8080'), findsOneWidget);
    debugPrint("STEP 9");
    await tester.tap(find.byKey(const Key('save-settings')));
    debugPrint("STEP 10");
    await tester.pumpAndSettle();

    // 配對頁:錯誤配對碼 → 紅色錯誤狀態
    expect(find.text('請輸入密碼'), findsOneWidget);
    debugPrint("STEP 11");
    await tester.tap(find.byKey(const Key('pairing-code')));
    debugPrint("STEP 12");
    await tester.pumpAndSettle();
    await _enterOnKeypad(tester, '1567960410');
    debugPrint("STEP 13");
    await tester.tap(find.byKey(const Key('pairing-confirm')));
    debugPrint("STEP 14");
    await tester.pumpAndSettle();
    expect(find.text('請重新輸入正確密碼'), findsOneWidget);

    // 正確配對碼 → 回到歡迎頁且可開始使用
    debugPrint("STEP 15");
    await tester.tap(find.byKey(const Key('pairing-code')));
    debugPrint("STEP 16");
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
    debugPrint("STEP 17");
      await tester.tap(find.byKey(const Key('key-backspace')));
    }
    await _enterOnKeypad(tester, '123456');
    debugPrint("STEP 18");
    await tester.tap(find.byKey(const Key('pairing-confirm')));
    debugPrint("STEP 19");
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('welcome-hint')), findsNothing);
    expect(env.services.storage.deviceConfig.paired, isTrue);
    await _teardown(tester, env);
  });

  testWidgets('capture flow: room → bed → 餐前 → confirm dialog', (
    tester,
  ) async {
    final env = await _pairedEnv();
    await _pumpApp(tester, env);

    debugPrint("STEP 20");
    await tester.tap(find.byKey(const Key('start-button')));
    debugPrint("STEP 21");
    await tester.pumpAndSettle();
    expect(find.text('在這裡開始進行拍照記錄!'), findsOneWidget);
    expect(find.text('門診'), findsOneWidget);

    debugPrint("STEP 22");
    await tester.tap(find.byKey(const Key('room-R101')));
    debugPrint("STEP 23");
    await tester.pumpAndSettle();
    expect(find.text('要幫誰紀錄呢?'), findsOneWidget);
    expect(find.text('床號1'), findsOneWidget);

    debugPrint("STEP 24");
    await tester.tap(find.byKey(const Key('bed-R101-B1')));
    debugPrint("STEP 25");
    await tester.pumpAndSettle();
    expect(find.text('新增食物攝取紀錄'), findsOneWidget);

    debugPrint("STEP 26");
    await tester.tap(find.byKey(const Key('phase-before')));
    debugPrint("STEP 27");
    await tester.pumpAndSettle();
    expect(find.text('確認放入餐點後進行下一步'), findsOneWidget);
    expect(find.byKey(const Key('next-step')), findsOneWidget);

    // 返回關閉對話框
    debugPrint("STEP 28");
    await tester.tap(find.bySemanticsLabel('返回').last);
    debugPrint("STEP 29");
    await tester.pumpAndSettle();
    expect(find.text('確認放入餐點後進行下一步'), findsNothing);
    await _teardown(tester, env);
  });

  testWidgets('records flow via drawer shows six meal tickets', (tester) async {
    final env = await _pairedEnv();
    await _pumpApp(tester, env);

    debugPrint("STEP 30");
    await tester.tap(find.byKey(const Key('start-button')));
    debugPrint("STEP 31");
    await tester.pumpAndSettle();

    debugPrint("STEP 32");
    await tester.tap(find.byKey(const Key('side-rail')));
    debugPrint("STEP 33");
    await tester.pumpAndSettle();
    expect(find.text('膳食攝影紀錄'), findsOneWidget);
    debugPrint("STEP 34");
    await tester.tap(find.byKey(const Key('menu-records')));
    debugPrint("STEP 35");
    await tester.pumpAndSettle();
    expect(find.text('在這裡可以查看攝影紀錄!'), findsOneWidget);

    debugPrint("STEP 36");
    await tester.tap(find.byKey(const Key('room-R102')));
    debugPrint("STEP 37");
    await tester.pumpAndSettle();
    expect(find.text('要查看誰的紀錄呢?'), findsOneWidget);

    debugPrint("STEP 38");
    await tester.tap(find.byKey(const Key('bed-R102-B1')));
    debugPrint("STEP 39");
    await tester.pumpAndSettle();
    for (final t in ['T1', 'T2', 'T3']) {
      expect(find.byKey(Key('ticket-$t-before')), findsOneWidget);
      expect(find.byKey(Key('ticket-$t-after')), findsOneWidget);
    }
    expect(find.byTooltip('未拍攝'), findsNWidgets(6));

    // 前一天
    final before = tester.widget<Text>(find.byKey(const Key('current-day')));
    debugPrint("STEP 40");
    await tester.tap(find.byKey(const Key('prev-day')));
    debugPrint("STEP 41");
    await tester.pumpAndSettle();
    final after = tester.widget<Text>(find.byKey(const Key('current-day')));
    expect(after.data, isNot(before.data));

    // 登出 → 回到歡迎頁
    debugPrint("STEP 42");
    await tester.tap(find.byKey(const Key('side-rail')));
    debugPrint("STEP 43");
    await tester.pumpAndSettle();
    debugPrint("STEP 44");
    await tester.tap(find.byKey(const Key('menu-logout')));
    debugPrint("STEP 45");
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('start-button')), findsOneWidget);
    await _teardown(tester, env);
  });
}
