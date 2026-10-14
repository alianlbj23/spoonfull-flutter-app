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
///
/// dispose 要在真實的 async 環境跑 ([WidgetTester.runAsync]):在 testWidgets
/// 的 FakeAsync 裡,關閉 stream 與資料庫的 future 不會完成,測試會卡到 10 分鐘逾時。
Future<void> _teardown(WidgetTester tester, TestEnv env) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(env.dispose);
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
    await tester.tap(find.byKey(const Key('welcome-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-settings')));
    await tester.pumpAndSettle();
    expect(find.text('*伺服器位址'), findsOneWidget);
    expect(find.text('*埠'), findsOneWidget);
    expect(find.text('*場域'), findsOneWidget);

    // 填寫設定;埠使用數字鍵盤
    await tester.enterText(find.byKey(const Key('field-host')), '10.0.0.5');
    await tester.enterText(find.byKey(const Key('field-place')), 'demo');
    await tester.tap(find.byKey(const Key('field-port')));
    await tester.pumpAndSettle();
    await _enterOnKeypad(tester, '8080');
    expect(find.text('8080'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-settings')));
    await tester.pumpAndSettle();

    // 配對頁:錯誤配對碼 → 紅色錯誤狀態
    expect(find.text('請輸入密碼'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pairing-code')));
    await tester.pumpAndSettle();
    await _enterOnKeypad(tester, '1567960410');
    await tester.tap(find.byKey(const Key('pairing-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('請重新輸入正確密碼'), findsOneWidget);

    // 正確配對碼 → 回到歡迎頁且可開始使用
    await tester.tap(find.byKey(const Key('pairing-code')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byKey(const Key('key-backspace')));
    }
    await _enterOnKeypad(tester, '123456');
    await tester.tap(find.byKey(const Key('pairing-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('welcome-hint')), findsNothing);
    expect(env.services.storage.deviceConfig.paired, isTrue);
    await _teardown(tester, env);
  });

  testWidgets('capture flow: room → bed → 餐前 → confirm dialog', (tester) async {
    final env = await _pairedEnv();
    await _pumpApp(tester, env);

    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pumpAndSettle();
    expect(find.text('在這裡開始進行拍照記錄!'), findsOneWidget);
    expect(find.text('門診'), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-R101')));
    await tester.pumpAndSettle();
    expect(find.text('要幫誰紀錄呢?'), findsOneWidget);
    expect(find.text('床號1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bed-R101-B1')));
    await tester.pumpAndSettle();
    expect(find.text('新增食物攝取紀錄'), findsOneWidget);

    await tester.tap(find.byKey(const Key('phase-before')));
    await tester.pumpAndSettle();
    expect(find.text('確認放入餐點後進行下一步'), findsOneWidget);
    expect(find.byKey(const Key('next-step')), findsOneWidget);
    expect(find.byKey(const Key('choose-file')), findsOneWidget);

    // 返回關閉對話框
    await tester.tap(find.bySemanticsLabel('返回').last);
    await tester.pumpAndSettle();
    expect(find.text('確認放入餐點後進行下一步'), findsNothing);
    await _teardown(tester, env);
  });

  testWidgets('records flow via drawer shows six meal tickets', (tester) async {
    final env = await _pairedEnv();
    await _pumpApp(tester, env);

    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('side-rail')));
    await tester.pumpAndSettle();
    expect(find.text('膳食攝影紀錄'), findsOneWidget);
    await tester.tap(find.byKey(const Key('menu-records')));
    await tester.pumpAndSettle();
    expect(find.text('在這裡可以查看攝影紀錄!'), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-R102')));
    await tester.pumpAndSettle();
    expect(find.text('要查看誰的紀錄呢?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bed-R102-B1')));
    await tester.pumpAndSettle();
    for (final t in ['T1', 'T2', 'T3']) {
      expect(find.byKey(Key('ticket-$t-before')), findsOneWidget);
      expect(find.byKey(Key('ticket-$t-after')), findsOneWidget);
    }
    expect(find.byTooltip('未拍攝'), findsNWidgets(6));

    // 前一天
    final before = tester.widget<Text>(find.byKey(const Key('current-day')));
    await tester.tap(find.byKey(const Key('prev-day')));
    await tester.pumpAndSettle();
    final after = tester.widget<Text>(find.byKey(const Key('current-day')));
    expect(after.data, isNot(before.data));

    // 登出 → 回到歡迎頁
    await tester.tap(find.byKey(const Key('side-rail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-logout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('start-button')), findsOneWidget);
    await _teardown(tester, env);
  });
}
