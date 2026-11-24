import 'package:dio/dio.dart';
import 'package:example/custom_router_pluggable.dart';
import 'package:example/detail_page.dart';
import 'package:example/home_page.dart';
import 'package:example/ume_switch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:ume/ume.dart';
// BlocInspector 所属 kit 尚未发布到 pub.dev，未包含在 ume façade 中，故 direct import。
import 'package:ume_kit_bloc_inspector/ume_kit_bloc_inspector.dart';

final Dio dio = Dio()
  ..options = BaseOptions(connectTimeout: Duration(seconds: 10));
final GetConnect get_connect = GetConnect();

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  BlocInspector.initialize();
  runApp(const UMEApp());
}

class UMEApp extends StatefulWidget {
  const UMEApp({Key? key}) : super(key: key);

  @override
  State<UMEApp> createState() => _UMEAppState();
}

class _UMEAppState extends State<UMEApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CustomRouterPluggable().navKey = navigatorKey;
    });
    if (kDebugMode) {
      PluginManager.instance
        // Bloc
        ..register(const BlocInspector())

        // Channel monitor
        // ..register(ChannelMonitor())

        // Channel observer
        ..register(ChannelObserver())

        // Clean local data
        ..register(DataCleanPanel())

        // Console
        ..register(Console())

        // Database
        ..register(DatabasePanel(databases: []))

        // Dark side
        ..register(DarkSide(context: context))

        // Designer check
        ..register(DesignerCheck())

        // Device
        // ..register(CpuInfoPage())
        // ..register(DeviceInfoPanel())
        // ..register(BatteryInfoPage())
        // ..register(NetworkInfoPage())
        ..register(DeviceInfo())

        // Git Info: run via `dart run ume:flutter run` to inject build metadata.
        ..register(const GitInfo())

        // Dio
        ..register(DioInspector(dio: dio))

        // GetConnect
        ..register(GetConnectInspector(connect: get_connect))

        // Memory detector
        ..register(MemoryDetectorButton())

        // ..register(const DBViewer())

        // Monitor
        // ..register(MonitorPlugin())
        // ..register(const MonitorActionsPlugin())

        // Perf
        ..register(Performance())
        ..register(MemoryInfoPage())

        // SharedPreferences
        ..register(SharedPreferencesInspector())

        // Show code
        ..register(ShowCode())

        // Slow animation
        ..register(SlowAnimation())

        // Storage
        // ..register(Storage())

        // UI inspector
        ..register(WidgetInfoInspector())
        ..register(WidgetDetailInspector())
        ..register(ColorSucker())
        ..register(AlignRuler())
        ..register(ColorPicker())
        ..register(TouchIndicator())

        // Custom router
        ..register(CustomRouterPluggable());
    }
  }

  Widget _buildApp(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'UME Demo',
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: HomePage(title: 'UME Demo Home Page'),
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case 'detail':
            return MaterialPageRoute(builder: (_) => const DetailPage());
          default:
            return null;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = _buildApp(context);
    if (kDebugMode) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => UMESwitch()),
        ],
        builder: (BuildContext context, _) => UMEWidget(
          enable: context.watch<UMESwitch>().enable,
          child: body,
        ),
      );
    }
    return body;
  }
}
