import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ==================== 协议常量（固定值，所有人相同，非用户数据） ====================
const String kBaseUrl = 'https://weapp.szajly.com';
const String kPathDetail = '/api/wechat/smart/lock/detail';
const String kPathOpen = '/api/wechat/smart/lock/open';
const String kPathRecord = '/api/wechat/smart/lock/open/record/result';
// 公区门禁
const String kPathGateList = '/api/wechat/smart/door/control';
const String kPathGateRemoteOpen = '/api/wechat/smart/door/control/remote/open';
const String kPathGateOpenRecord = '/api/wechat/smart/door/control/open/record';

// 小程序固定标识（实测服务端不校验，全平台统一）
const String kWxMiniAppId = 'wxb8f1a397304ee2ba';
const String kModel = 'microsoft';
const String kSystem = 'Windows 11 x64';
const String kAppVersion = '4.1.15.13';

const String kRoomServiceUuid = '00000001-0000-1000-8000-00805f9b34fb';
// 开门服务内特征（HCI 日志实测）：0x0002 写指令 / 0x0003 回包通知
const String kWriteCharUuid = '00000002-0000-1000-8000-00805f9b34fb';
const String kNotifyCharUuid = '00000003-0000-1000-8000-00805f9b34fb';

// WAF 校验 UA，必须伪装成微信小程序（与实测可用的请求头保持一致）
const String kUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36 '
    'MicroMessenger/7.0.20.1781(0x6700143B) NetType/WIFI '
    'MiniProgramEnv/Windows WindowsWechat/WMPF';

// ==================== 配色（白底浅灰，不用黑色） ====================
const Color kBlue = Color(0xFF3A7AFE);
const Color kBlueSoft = Color(0xFFEAF1FF);
const Color kGreen = Color(0xFF07C160);
const Color kOrange = Color(0xFFF08C00);
const Color kTextDark = Color(0xFF2B2F36);
const Color kTextGray = Color(0xFF9AA0A8);
const Color kCardGray = Color(0xFFF5F6F8);
const Color kLogGray = Color(0xFF6B7280);

void main() {
  runApp(const DoorApp());
}

class DoorApp extends StatelessWidget {
  const DoorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '门锁开门',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: kBlue, brightness: Brightness.light),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const HomePage(),
    );
  }
}

// ==================== 运行时配置（多配置文件） ====================
class _FieldDef {
  final String key, label, desc;
  const _FieldDef(this.key, this.label, this.desc);
}

// 参数字段表：label=界面显示名，desc=从哪个请求抓+含义
const List<_FieldDef> _kFields = [
  _FieldDef('token', 'applet-token（登录态令牌）',
      '唯一要抓包的长串。服务端身份凭证，会过期（App 提示 401 时重抓）。\n'
      '抓包：打开小程序，任意 weapp.szajly.com 请求的 '
      'applet-token 请求头，整段照抄。\n'),
  _FieldDef('mac', '门锁 MAC（蓝牙地址）',
      '不用手填：点下方"自动获取"按钮，App 调 lock/detail 接口自动填入。'),
  _FieldDef('tenant_id', 'tenantId（租户ID）',
      '你的租户编号。同一个抓包请求里的 tenantId 请求头，照抄。'),
  _FieldDef('company_id', 'companyId（公司/门店ID）',
      '公寓运营方编号。请求头 companyId，照抄。'),
  _FieldDef('customer_id', 'customerId（用户ID）',
      '你的账号编号。请求头 customerId，照抄。'),
];

// 分组显示
const _groupRequired = ['token', 'mac'];
const _groupIdentity = ['tenant_id', 'company_id', 'customer_id'];

// 当前生效配置（= 激活 profile 的内容）
final Map<String, String> _cfg = {};
String _cfgVal(String key) => _cfg[key] ?? '';

// 全部配置文件 + 激活名
final Map<String, Map<String, String>> _profiles = {};
String _activeProfile = '';

// 设置页保存成功后带回首页显示的提示
String _toastAfterSettings = '';

void _applyActive() {
  final prof = _profiles[_activeProfile] ?? {};
  for (final f in _kFields) {
    _cfg[f.key] = prof[f.key] ?? '';
  }
}

Future<void> _saveProfiles() async {
  final p = await SharedPreferences.getInstance();
  await p.setString(
      'profiles_v2',
      jsonEncode(_profiles
          .map((name, v) => MapEntry(name, v.map((k, x) => MapEntry(k, x))))));
  await p.setString('active_profile', _activeProfile);
}

Future<void> _loadProfiles() async {
  final p = await SharedPreferences.getInstance();
  _profiles.clear();
  final raw = p.getString('profiles_v2');
  if (raw != null) {
    try {
      (jsonDecode(raw) as Map<String, dynamic>).forEach((name, v) {
        _profiles[name] = Map<String, String>.from(v as Map);
      });
    } catch (_) {}
  }
  _activeProfile = p.getString('active_profile') ?? '';
  // 一次性迁移：旧版 cfg_* / custom_token 数据收进"默认"配置
  if (_profiles.isEmpty) {
    final legacy = <String, String>{};
    for (final f in _kFields) {
      final v = p.getString('cfg_${f.key}') ?? '';
      if (v.isNotEmpty) legacy[f.key] = v;
    }
    final oldToken = p.getString('custom_token') ?? '';
    if (oldToken.isNotEmpty && (legacy['token'] ?? '').isEmpty) {
      legacy['token'] = oldToken;
    }
    if (legacy.isNotEmpty) {
      _profiles['默认'] = legacy;
      _activeProfile = '默认';
      await _saveProfiles();
    }
  }
  if ((_activeProfile.isEmpty || !_profiles.containsKey(_activeProfile)) &&
      _profiles.isNotEmpty) {
    _activeProfile = _profiles.keys.first;
  }
  _applyActive();
}

// ==================== 服务端 API ====================
Map<String, String> _apiHeaders() => {
      'applet-token': _cfgVal('token'),
      'tenantId': _cfgVal('tenant_id'),
      'companyId': _cfgVal('company_id'),
      'customerId': _cfgVal('customer_id'),
      'businessType': '1',
      'cohabitId': '0',
      'sessionId': '',
      'platform': 'MiniApp',
      'version': '1',
      'Content-Type': 'application/json; charset=UTF-8',
      'wxMiniAppId': kWxMiniAppId,
      'model': kModel,
      'system': kSystem,
      'appVersion': kAppVersion,
      'user-agent': kUserAgent,
    };

Future<Map<String, dynamic>> _apiRequest(
    String method, String path, Map<String, dynamic>? body) async {
  if (_cfgVal('token').isEmpty) throw '未配置 applet-token：请点右上角齿轮填写';
  final uri = Uri.parse(kBaseUrl + path);
  http.Response resp;
  try {
    if (method == 'GET') {
      resp = await http
          .get(uri, headers: _apiHeaders())
          .timeout(const Duration(seconds: 30));
    } else {
      resp = await http
          .post(uri, headers: _apiHeaders(), body: jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 30));
    }
  } catch (e) {
    throw '网络异常: $e';
  }
  Map<String, dynamic> map;
  try {
    map = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  } catch (_) {
    throw '服务返回非 JSON (HTTP ${resp.statusCode})，可能 token 过期或被拦截';
  }
  final code = map['code'];
  if (resp.statusCode == 401 || code == 401 || code == 402) {
    throw '登录态失效(401)，请到设置页更新 applet-token';
  }
  return map;
}

String _openTime() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  // 与小程序一致：月/日/时不补零
  return '${n.year}-${n.month}-${n.day} ${n.hour}:${two(n.minute)}:${two(n.second)}';
}

List<int> hexToBytes(String h) {
  final s = h.replaceAll(RegExp(r'[\s,]'), '');
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}

String bytesHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

// ==================== 蓝牙开门 ====================
class _LockLink {
  final BluetoothDevice dev;
  final BluetoothCharacteristic notifyCh;
  final BluetoothCharacteristic writeCh;
  _LockLink(this.dev, this.notifyCh, this.writeCh);

  Future<void> close() async {
    try {
      await dev.disconnect();
    } catch (_) {}
  }
}

/// 扫描 -> 连接 -> 发现服务，返回可写链路。扫到目标立即停扫（不死等超时）。
Future<_LockLink> _connectLock({
  required String mac,
  required void Function(String) log,
}) async {
  final macClean = mac.toUpperCase().replaceAll(':', '');

  // 1. 确保蓝牙开启
  var state = await FlutterBluePlus.adapterState.first;
  if (state != BluetoothAdapterState.on) {
    log('蓝牙未开启，请求打开...');
    await FlutterBluePlus.turnOn();
    state = await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first
        .timeout(const Duration(seconds: 10),
            onTimeout: () => BluetoothAdapterState.off);
    if (state != BluetoothAdapterState.on) {
      throw '蓝牙未能开启，请手动打开后重试';
    }
  }

  // 2. 扫描目标锁（只认精确 MAC；找到立即停扫）
  log('扫描门锁 $mac ...');
  final found = Completer<BluetoothDevice>();
  final scanSub = FlutterBluePlus.scanResults.listen((rs) {
    for (final r in rs) {
      final a = r.device.remoteId.str.toUpperCase().replaceAll(':', '');
      if (a == macClean && !found.isCompleted) {
        found.complete(r.device);
      }
    }
  });
  await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
  BluetoothDevice dev;
  try {
    dev = await found.future.timeout(const Duration(seconds: 9),
        onTimeout: () => throw '未发现门锁：请站在门边，摸一下键盘点亮屏幕唤醒锁的蓝牙后重试');
  } finally {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    scanSub.cancel();
  }
  log('发现设备: ${dev.platformName.isEmpty ? '(无名)' : dev.platformName} '
      '${dev.remoteId.str}');

  // 3. 连接 + 服务发现（弱信号下可重试）
  BluetoothCharacteristic? notifyCh, writeCh;
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      log('连接中($attempt/3)...');
      await dev.connect(license: License.nonprofit); // 个人用途免费授权
      log('已连接，发现服务...');
      final services = await dev.discoverServices();
      BluetoothService? svc;
      for (final s in services) {
        // 必须用 str128：fbp 的 str 对 16-bit UUID 返回 "0001" 短形式
        if (s.uuid.str128.toLowerCase() == kRoomServiceUuid) svc = s;
      }
      if (svc != null) {
        for (final c in svc.characteristics) {
          if (notifyCh == null &&
              (c.properties.notify || c.properties.indicate)) {
            notifyCh = c;
          }
          if (writeCh == null &&
              (c.properties.write || c.properties.writeWithoutResponse)) {
            writeCh = c;
          }
        }
      }
      // 兜底：按特征 UUID 精确匹配（HCI 日志实测：写=0x0002  notify=0x0003）
      if (notifyCh == null || writeCh == null) {
        for (final s in services) {
          for (final c in s.characteristics) {
            final u = c.uuid.str128.toLowerCase();
            if (u == kWriteCharUuid) writeCh ??= c;
            if (u == kNotifyCharUuid) notifyCh ??= c;
          }
        }
      }
      if (notifyCh == null || writeCh == null) {
        throw '缺少 notify/write 特征';
      }
      return _LockLink(dev, notifyCh, writeCh);
    } catch (e) {
      notifyCh = null;
      writeCh = null;
      if (attempt == 3) throw '连接失败: $e';
      log('连接失败($attempt/3): $e');
      try {
        await dev.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 1000));
    }
  }
  throw '连接失败';
}

/// 订阅 -> 写 9A 帧指令 -> 等 EE08（时序对齐小程序）
Future<bool> _sendCommand({
  required _LockLink link,
  required List<List<int>> packets,
  required void Function(String) log,
}) async {
  final n = link.notifyCh;
  final w = link.writeCh;
  final ee = Completer<void>();
  final vsub = n.onValueReceived.listen((value) {
    final hx = bytesHex(value);
    log('回包: $hx');
    if (hx.contains('EE08') && !ee.isCompleted) ee.complete();
  });
  try {
    await n.setNotifyValue(true);
    await Future.delayed(const Duration(milliseconds: 300));
    await Future.delayed(const Duration(milliseconds: 550));
    final withResp = w.properties.write;
    for (var i = 0; i < packets.length; i++) {
      await w.write(packets[i], withoutResponse: !withResp);
      log('发送 ${i + 1}/${packets.length}: ${bytesHex(packets[i])}');
      if (i < packets.length - 1) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
    log('等待锁确认 (EE08) ...');
    try {
      await ee.future.timeout(const Duration(seconds: 20));
      return true;
    } on TimeoutException {
      return false;
    }
  } finally {
    vsub.cancel();
  }
}

// ==================== 页面 ====================
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const List<String> _stepTitles = [
    '取指令并连门锁',
    '蓝牙就绪',
    '发送指令',
    '确认开门',
  ];
  static const List<String> _stepDescs = [
    '并行：服务端取一次性指令 + 蓝牙扫描连接',
    '连接成功，服务发现完成',
    '写入指令帧（对齐小程序时序）',
    '等待锁回码 EE08 并上报记录',
  ];

  bool _busy = false;
  bool _success = false;
  int _step = -1; // 当前执行到的步骤下标
  int _failedStep = -1;
  String _status = '待命中，点击下方按钮开门';
  Color _statusColor = kTextGray;
  String _lockSub = '正在获取门锁信息...';
  String _lockAddr = '';
  final List<String> _logs = [];
  final ScrollController _logCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadProfiles();
      _refreshLockInfo();
    });
  }

  Future<void> _openSettings() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SettingsPage()));
    await _loadProfiles(); // 设置可能改了配置/切换了 profile，回来后刷新
    if (!mounted) return;
    if (_toastAfterSettings.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_toastAfterSettings,
            style: const TextStyle(fontSize: 13)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
      _toastAfterSettings = '';
    }
    _refreshLockInfo();
    setState(() {});
  }

  Future<void> _refreshLockInfo() async {
    try {
      final d = await _apiRequest('GET', kPathDetail, null);
      if (d['code'] == 200 && d['data'] is Map) {
        final lock = Map<String, dynamic>.from(d['data'] as Map);
        if (!mounted) return;
        setState(() {
          _lockSub = '云丁智能 · ${lock['mac'] ?? _cfgVal('mac')}';
          _lockAddr = (lock['address'] ?? '').toString();
        });
        _log('门锁信息已刷新 (id=${lock['id']})');
      }
    } catch (e) {
      if (!mounted) return;
      final mac = _cfgVal('mac');
      setState(() =>
          _lockSub = mac.isEmpty ? '未配置门锁信息' : '云丁智能 · $mac');
      _log('门锁信息获取失败: $e');
    }
  }

  void _log(String s) {
    final n = DateTime.now();
    final ts =
        '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}:${n.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() => _logs.add('$ts  $s'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logCtrl.hasClients) {
        _logCtrl.jumpTo(_logCtrl.position.maxScrollExtent);
      }
    });
  }

  void _stepTo(int i, String msg) {
    if (!mounted) return;
    setState(() {
      _step = i;
      _failedStep = -1;
      _success = false;
      _status = msg;
      _statusColor = kBlue;
    });
    _log(msg);
  }

  Future<void> _ensurePermissions() async {
    // iOS/macOS 不走 permission_handler：其 PERMISSION_* 编译宏在 SPM 集成下
    // 默认关闭，request() 会误报"永久拒绝"且系统弹窗不出现。
    // iOS 上 CoreBluetooth 首次使用时自动弹系统蓝牙授权，无需（也不能）代劳。
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      _log('iOS 蓝牙授权将由系统弹窗询问');
      return;
    }
    final statuses = await [
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final denied = statuses.entries
        .where((e) => !e.value.isGranted && !e.value.isLimited)
        .toList();
    if (denied.isNotEmpty) {
      throw '蓝牙/定位权限未授予，请到系统设置里开启';
    }
    try {
      final locOn = await Permission.locationWhenInUse.serviceStatus.isEnabled;
      if (!locOn) {
        _log('提示: 旧安卓系统需开启系统定位服务才能扫描蓝牙');
      }
    } catch (_) {}
  }

  Future<void> _open() async {
    if (_busy) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _success = false;
      _failedStep = -1;
      _step = -1;
      _logs.clear();
      _status = '准备中...';
      _statusColor = kBlue;
    });
    _LockLink? link;
    Future<_LockLink>? linkFuture;
    try {
      _log('申请蓝牙权限...');
      await _ensurePermissions();

      // MAC 来源：当前配置手填 > lock/detail 自动查询
      var mac = _cfgVal('mac');
      Future<Map<String, dynamic>>? cmdFuture;
      if (mac.isEmpty) {
        _stepTo(0, '查询门锁信息...');
        try {
          final d = await _apiRequest('GET', kPathDetail, null);
          if (d['code'] == 200 && d['data'] is Map) {
            mac = (Map<String, dynamic>.from(d['data'] as Map)['mac'] ?? '')
                .toString();
          }
        } catch (e) {
          _log('查询门锁信息失败: $e');
        }
        if (mac.isEmpty) {
          throw '未获取到门锁 MAC：请到设置页手动填写';
        }
        _log('门锁 MAC: $mac');
      } else {
        _log('门锁 MAC(配置): $mac');
      }

      // 并行：取一次性开门指令 + 蓝牙连接门锁
      _stepTo(0, '并行获取指令与连接门锁...');
      cmdFuture = _apiRequest('POST', kPathOpen, {});
      linkFuture = _connectLock(mac: mac, log: (m) => _log(m));

      // 指令先回来先解析；蓝牙连上后写指令
      final c = await cmdFuture;
      if (c['code'] != 200 || c['data'] is! Map) {
        throw '取指令失败: ${c['msg'] ?? c}';
      }
      final cmdData = Map<String, dynamic>.from(c['data'] as Map);
      final lockId = cmdData['id'];
      final packets = cmdData['command']
          .toString()
          .split(',')
          .where((s) => s.trim().isNotEmpty)
          .map(hexToBytes)
          .toList();
      if (packets.isEmpty) throw '指令为空';
      _log('已取新指令 id=$lockId，共 ${packets.length} 包');

      _stepTo(1, '等待蓝牙连接...');
      link = await linkFuture;

      // 写指令并等确认
      _stepTo(2, '发送开门指令...');
      final ok = await _sendCommand(link: link, packets: packets, log: (m) => _log(m));
      if (!mounted) return;

      // 确认 + 上报
      if (!ok) {
        setState(() {
          _failedStep = 3;
          _status = '未收到 EE08 确认，指令可能已作废，再按一次即可';
          _statusColor = kOrange;
        });
        _log('未收到 EE08（指令可能已作废，重试会取新指令）');
        return;
      }
      setState(() {
        _step = 3;
        _success = true;
        _status = '开门成功！';
        _statusColor = kGreen;
      });
      HapticFeedback.mediumImpact();
      _log('上报开门记录...');
      try {
        await _apiRequest('POST', kPathRecord, {
          'id': lockId,
          'openResult': '',
          'openTime': _openTime(),
        });
        _log('上报完成');
      } catch (e) {
        _log('上报失败(不影响开门): $e');
      }
    } catch (e) {
      // 若指令阶段先失败，蓝牙可能还在连：连上后立即断开，避免一直占着锁
      linkFuture?.then((l) => l.close()).ignore();
      if (!mounted) return;
      setState(() {
        if (_step >= 0 && _failedStep < 0) _failedStep = _step;
        _status = '$e';
        _statusColor = kOrange;
      });
      _log('失败: $e');
    } finally {
      link?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _stepIcon(int i) {
    if (i == _failedStep) {
      return const Icon(Icons.cancel_rounded, color: kOrange, size: 22);
    }
    if (_success && i <= _step) {
      return const Icon(Icons.check_circle_rounded, color: kGreen, size: 22);
    }
    if (i < _step || (_success && i == _step)) {
      return const Icon(Icons.check_circle_rounded, color: kGreen, size: 22);
    }
    if (i == _step && !_success) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.2, color: kBlue),
      );
    }
    return Icon(Icons.radio_button_unchecked, color: Colors.grey.shade300,
        size: 22);
  }

  Color _stepTitleColor(int i) {
    if (i == _failedStep) return kOrange;
    if (i <= _step) return kTextDark;
    return kTextGray;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: const Text('门锁开门',
            style: TextStyle(
                color: kTextDark, fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: kTextGray),
            tooltip: '参数设置',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            // ---- 门锁信息卡 ----
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kCardGray,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: kBlueSoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.door_front_door,
                        color: kBlue, size: 26),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('房门锁',
                            style: TextStyle(
                                color: kTextDark,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(_lockSub,
                            style:
                                const TextStyle(color: kTextGray, fontSize: 12)),
                        if (_lockAddr.isNotEmpty)
                          Text(_lockAddr,
                              style: const TextStyle(
                                  color: kTextGray, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ---- 步骤卡 ----
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kCardGray,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: List.generate(4, (i) {
                  return Padding(
                    padding: EdgeInsets.only(bottom: i == 3 ? 0 : 14),
                    child: Row(
                      children: [
                        _stepIcon(i),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_stepTitles[i],
                                  style: TextStyle(
                                      color: _stepTitleColor(i),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              Text(_stepDescs[i],
                                  style: const TextStyle(
                                      color: kTextGray, fontSize: 11)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 16),

            // ---- 状态 ----
            Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _statusColor,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),

            // ---- 开门按钮 ----
            SizedBox(
              height: 54,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: kBlue,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: kBlue.withValues(alpha: 0.45),
                  shape: const StadiumBorder(),
                ),
                onPressed: _busy ? null : _open,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_busy ? Icons.hourglass_top_rounded : Icons.lock_open_rounded,
                        size: 21),
                    const SizedBox(width: 8),
                    Text(_busy ? '开门中...' : '一键开门',
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text('请站在门边操作，保持手机靠近门锁',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextGray, fontSize: 11)),
            const SizedBox(height: 14),

            // ---- 公区门禁入口 ----
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const GatePage())),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                    color: kCardGray, borderRadius: BorderRadius.circular(16)),
                child: const Row(
                  children: [
                    Icon(Icons.door_front_door_outlined,
                        color: kBlue, size: 22),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('公区门禁',
                              style: TextStyle(
                                  color: kTextDark,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                          Text('大门 / 侧门 / 屋面，远程开门不用贴门',
                              style:
                                  TextStyle(color: kTextGray, fontSize: 11)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: kTextGray),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ---- 日志 ----
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 6),
              child: Text('运行日志',
                  style: TextStyle(
                      color: kTextGray,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ),
            Container(
              height: 230,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kCardGray,
                borderRadius: BorderRadius.circular(16),
              ),
              child: _logs.isEmpty
                  ? const Center(
                      child: Text('暂无日志',
                          style: TextStyle(color: kTextGray, fontSize: 12)))
                  : ListView.builder(
                      controller: _logCtrl,
                      itemCount: _logs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(_logs[i],
                            style: const TextStyle(
                                color: kLogGray,
                                fontSize: 11,
                                height: 1.45,
                                fontFamily: 'monospace')),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 参数设置页（多配置文件） ====================
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, TextEditingController> _ctrls = {};
  String _current = _activeProfile;

  @override
  void initState() {
    super.initState();
    for (final f in _kFields) {
      _ctrls[f.key] = TextEditingController();
    }
    _loadIntoForm(_current);
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _loadIntoForm(String name) {
    final prof = _profiles[name] ?? {};
    for (final f in _kFields) {
      _ctrls[f.key]!.text = prof[f.key] ?? '';
    }
  }

  // token/mac 粘贴可能带换行空格要清掉；system 等值本身含空格只 trim
  String _clean(String key, String v) {
    v = v.trim();
    if (key == 'token' || key == 'mac') {
      v = v.replaceAll(RegExp(r'\s'), '');
    }
    return v;
  }

  Map<String, String> _formData() {
    final out = <String, String>{};
    for (final f in _kFields) {
      final v = _clean(f.key, _ctrls[f.key]!.text);
      if (v.isNotEmpty) out[f.key] = v;
    }
    return out;
  }

  Future<String?> _askName(String title) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(title,
            style: const TextStyle(color: kTextDark, fontSize: 15)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: kTextDark, fontSize: 14),
          decoration: InputDecoration(
            hintText: '配置名称，如：106房',
            hintStyle: const TextStyle(color: kTextGray, fontSize: 13),
            filled: true,
            fillColor: kCardGray,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: kTextGray))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kBlue),
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_current.isEmpty) {
      final name = await _askName('保存为新配置');
      if (name == null || name.isEmpty) return;
      _current = name;
    }
    _profiles[_current] = _formData();
    _activeProfile = _current;
    await _saveProfiles();
    _applyActive();
    _toastAfterSettings = '已保存配置「$_current」，已生效';
    if (mounted) Navigator.pop(context);
  }

  Future<void> _switchTo(String name) async {
    if (name == _current) return;
    if (_current.isNotEmpty) {
      _profiles[_current] = _formData(); // 切换前静默保存当前表单，防丢
    }
    _current = name;
    _activeProfile = name; // 记住上次使用的配置
    await _saveProfiles();
    _applyActive();
    setState(() => _loadIntoForm(name));
  }

  Future<void> _newProfile() async {
    final name = await _askName('新建配置（一把锁一个）');
    if (name == null || name.isEmpty) return;
    if (_current.isNotEmpty) _profiles[_current] = _formData();
    // 以当前表单内容为模板，通常只需改 token 和 MAC
    _profiles[name] = _formData();
    _current = name;
    _activeProfile = name;
    await _saveProfiles();
    _applyActive();
    setState(() {});
  }

  Future<void> _deleteProfile() async {
    if (_current.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('删除配置',
            style: TextStyle(color: kTextDark, fontSize: 15)),
        content: Text('确定删除“$_current”？此操作不可恢复。',
            style: const TextStyle(color: kTextDark, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: kTextGray))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kOrange),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    _profiles.remove(_current);
    _current = _profiles.isNotEmpty ? _profiles.keys.first : '';
    _activeProfile = _current;
    await _saveProfiles();
    _applyActive();
    setState(() => _loadIntoForm(_current));
  }

  void _clearForm() {
    for (final c in _ctrls.values) {
      c.text = '';
    }
    setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  bool _fetchingMac = false;

  // 用表单里的 token+身份信息调 lock/detail，把 MAC（和门锁地址）自动填回来
  Future<void> _autoFetchMac() async {
    String v(String k) => _clean(k, _ctrls[k]!.text);
    // 先本地校验，缺什么直接说明，避免服务端笼统报"身份信息不完整"
    final missing = <String>[];
    if (v('token').isEmpty) missing.add('applet-token');
    if (v('tenant_id').isEmpty) missing.add('tenantId');
    if (v('company_id').isEmpty) missing.add('companyId');
    if (v('customer_id').isEmpty) missing.add('customerId');
    if (missing.isNotEmpty) {
      _toast('还差 ${missing.join('、')}，先填好再点自动获取');
      return;
    }
    setState(() => _fetchingMac = true);
    try {
      final headers = {
        'applet-token': v('token'),
        'tenantId': v('tenant_id'),
        'companyId': v('company_id'),
        'customerId': v('customer_id'),
        'businessType': '1', 'cohabitId': '0', 'sessionId': '',
        'platform': 'MiniApp', 'version': '1',
        'Content-Type': 'application/json; charset=UTF-8',
        'wxMiniAppId': kWxMiniAppId, 'model': kModel,
        'system': kSystem, 'appVersion': kAppVersion,
        'user-agent': kUserAgent,
      };
      final resp = await http
          .get(Uri.parse(kBaseUrl + kPathDetail), headers: headers)
          .timeout(const Duration(seconds: 30));
      final body =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (body['code'] == 200 && body['data'] is Map) {
        final d = Map<String, dynamic>.from(body['data'] as Map);
        final mac = (d['mac'] ?? '').toString();
        if (mac.isNotEmpty) {
          setState(() => _ctrls['mac']!.text = mac);
          _toast('已获取 ${d['address'] ?? ''} · $mac');
        } else {
          _toast('接口未返回 MAC');
        }
      } else {
        _toast('获取失败: ${body['msg'] ?? body['code']}（检查 token 和身份信息）');
      }
    } catch (e) {
      _toast('获取失败: $e');
    } finally {
      if (mounted) setState(() => _fetchingMac = false);
    }
  }

  Widget _fieldTile(_FieldDef f) {
    final isToken = f.key == 'token';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(f.label,
              style: const TextStyle(
                  color: kTextDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(f.desc,
              style:
                  const TextStyle(color: kTextGray, fontSize: 11, height: 1.4)),
          const SizedBox(height: 6),
          TextField(
            controller: _ctrls[f.key],
            maxLines: isToken ? 3 : 1,
            style: const TextStyle(color: kTextDark, fontSize: 12.5),
            decoration: InputDecoration(
              hintText: isToken ? '粘贴 applet-token' : '未填写',
              hintStyle: const TextStyle(color: kTextGray, fontSize: 11.5),
              filled: true,
              fillColor: Colors.white,
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: kBlue)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            ),
          ),
          if (f.key == 'mac') ...[
            const SizedBox(height: 4),
            SizedBox(
              height: 32,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                    foregroundColor: kBlue,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                onPressed: _fetchingMac ? null : _autoFetchMac,
                icon: _fetchingMac
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: kBlue))
                    : const Icon(Icons.download_outlined, size: 16),
                label: Text(_fetchingMac ? '获取中...' : '自动获取',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _groupCard(String title, String subtitle, List<String> keys,
      {Color bg = kCardGray}) {
    final fields = _kFields.where((f) => keys.contains(f.key)).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: kTextDark,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(subtitle,
              style: const TextStyle(color: kTextGray, fontSize: 11)),
          const SizedBox(height: 12),
          ...fields.map(_fieldTile),
        ],
      ),
    );
  }

  Widget _profileBar() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration:
          BoxDecoration(color: kBlueSoft, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Expanded(
            child: _profiles.isEmpty
                ? const Text('还没有配置，填好下面参数后点保存',
                    style: TextStyle(color: kTextGray, fontSize: 12.5))
                : DropdownButton<String>(
                    value: _current.isEmpty ? null : _current,
                    isExpanded: true,
                    underline: const SizedBox(),
                    iconEnabledColor: kBlue,
                    dropdownColor: Colors.white,
                    style: const TextStyle(
                        color: kTextDark,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                    items: _profiles.keys
                        .map((n) => DropdownMenuItem(
                            value: n,
                            child: Text(n, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) _switchTo(v);
                    },
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: kBlue),
            tooltip: '新建配置',
            onPressed: _newProfile,
          ),
          IconButton(
            icon: Icon(Icons.delete_outline,
                color: _profiles.isEmpty ? Colors.grey.shade300 : kOrange),
            tooltip: '删除当前配置',
            onPressed: _profiles.isEmpty ? null : _deleteProfile,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: kTextDark),
        title: const Text('参数设置',
            style: TextStyle(
                color: kTextDark, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            _profileBar(),
            // 抓包方法说明
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: kCardGray, borderRadius: BorderRadius.circular(16)),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('参数从哪来（一次性抓包）',
                      style: TextStyle(
                          color: kBlue,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 6),
                  Text(
                    '1. 电脑开 Charles / mitmproxy，手机挂代理并装证书\n'
                    '2. 微信打开安居丽业小程序，进“智能门锁”页面\n'
                    '3. 抓任意一个 weapp.szajly.com 的请求，把 applet-token、tenantId、'
                    'companyId、customerId 四个请求头抄进来\n'
                    '4. MAC 不用抄，回这里点“自动获取”。多把锁就新建多个配置，一键切换。',
                    style:
                        TextStyle(color: kTextDark, fontSize: 11.5, height: 1.5),
                  ),
                ],
              ),
            ),
            _groupCard('必填', 'token 抓包照抄；MAC 点“自动获取”即可', _groupRequired,
                bg: kBlueSoft),
            _groupCard('身份信息', '同一个抓包请求里的请求头，照抄即可', _groupIdentity),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kTextGray,
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _clearForm,
                    child: const Text('清空表单'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kBlue,
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _save,
                    child: Text(_current.isEmpty ? '保存' : '保存到“$_current”'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


// ==================== 公区门禁页 ====================
class GatePage extends StatefulWidget {
  const GatePage({super.key});

  @override
  State<GatePage> createState() => _GatePageState();
}

class _GatePageState extends State<GatePage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _doors = [];
  final Set<int> _opening = {};
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _log(String s) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    if (!mounted) return;
    setState(() => _logs.add('${two(n.hour)}:${two(n.minute)}:${two(n.second)}  $s'));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await _apiRequest('GET', kPathGateList, null);
      if (d['code'] == 200 && d['data'] is List) {
        _doors = (d['data'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _log('获取到 ${_doors.length} 台门禁');
      } else {
        _error = '获取失败: ${d['msg'] ?? d['code']}';
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openDoor(Map<String, dynamic> door) async {
    final id = door['id'];
    final name = door['deviceName'] ?? '门禁';
    setState(() => _opening.add(id));
    _log('远程开门: $name (id=$id) ...');
    try {
      final r = await _apiRequest('POST', kPathGateRemoteOpen, {'id': id});
      if (r['code'] == 200) {
        _log('$name 开门成功');
        _toast('$name 已远程开启');
        HapticFeedback.mediumImpact();
      } else {
        _log('$name 失败: code=${r['code']} msg=${r['msg']}');
        _toast('失败: ${r['msg'] ?? r['code']}');
      }
    } catch (e) {
      _log('$name 异常: $e');
      _toast('$e');
    } finally {
      if (mounted) setState(() => _opening.remove(id));
    }
  }

  Widget _chip(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(color: color, fontSize: 10.5)),
    );
  }

  Widget _doorCard(Map<String, dynamic> d) {
    final id = d['id'];
    final remote = d['isSupportRemote'] == '1';
    final network = d['isSupportNetwork'] == '1';
    final busy = _opening.contains(id);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration:
          BoxDecoration(color: kCardGray, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.meeting_room_outlined, color: kBlue, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d['deviceName'] ?? '门禁',
                    style: const TextStyle(
                        color: kTextDark,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(d['address'] ?? '',
                    style: const TextStyle(color: kTextGray, fontSize: 11.5)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (network) _chip('联网', kGreen),
                    if (remote) _chip('支持远程', kBlue),
                    if (!remote) _chip('仅蓝牙/密码', kOrange),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: remote ? kBlue : Colors.grey.shade300,
              foregroundColor: Colors.white,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: (!remote || busy) ? null : () => _openDoor(d),
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('开门', style: TextStyle(fontSize: 13.5)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: kTextDark),
        title: const Text('公区门禁',
            style: TextStyle(
                color: kTextDark, fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh, color: kTextGray),
              onPressed: _load),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kBlue))
            : _error != null
                ? Center(
                    child: Text(_error!,
                        style: const TextStyle(color: kOrange, fontSize: 13)))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    children: [
                      ..._doors.map(_doorCard),
                      if (_logs.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        const Text('运行日志',
                            style: TextStyle(
                                color: kTextGray,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                              color: kCardGray,
                              borderRadius: BorderRadius.circular(12)),
                          child: Text(_logs.reversed.take(20).join('\n'),
                              style: const TextStyle(
                                  color: kLogGray,
                                  fontSize: 11,
                                  height: 1.45,
                                  fontFamily: 'monospace')),
                        ),
                      ],
                    ],
                  ),
      ),
    );
  }
}
