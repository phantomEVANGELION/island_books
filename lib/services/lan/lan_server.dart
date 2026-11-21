import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 上传回调：拿到文件名和字节，交给导入流程处理
typedef UploadHandler = Future<void> Function(String fileName, List<int> bytes);

/// 局域网传书服务。
///
/// 手机开一个 HTTP 服务，电脑浏览器打开 http://<手机IP>:<端口> 就能拖 epub 进来。
/// 只监听局域网、只在用户主动开启时运行，关掉就停。
class LanServer {
  HttpServer? _server;
  int _port = 0;
  int _received = 0;

  bool get isRunning => _server != null;
  int get port => _port;
  int get receivedCount => _received;

  /// 启动服务，返回本机局域网 IP（拿不到返回 null）
  Future<String?> start({required UploadHandler onUpload, int port = 8080}) async {
    if (_server != null) return localIp();

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } catch (_) {
      // 8080 被占用就随机分配一个
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _port = _server!.port;

    _server!.listen((req) => _handle(req, onUpload));
    return localIp();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _received = 0;
  }

  Future<void> _handle(HttpRequest req, UploadHandler onUpload) async {
    try {
      final path = req.uri.path;

      if (req.method == 'GET' && (path == '/' || path.isEmpty)) {
        req.response.headers.contentType = ContentType.html;
        req.response.write(_page);
        await req.response.close();
        return;
      }

      if (req.method == 'POST' && path == '/upload') {
        final name = req.uri.queryParameters['name'] ?? 'book.epub';
        final bytes = <int>[];
        await for (final chunk in req) {
          bytes.addAll(chunk);
        }
        if (bytes.isEmpty) {
          req.response.statusCode = 400;
          req.response.write(jsonEncode({'ok': false, 'error': '空文件'}));
          await req.response.close();
          return;
        }

        await onUpload(name, bytes);
        _received++;

        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': true, 'name': name, 'size': bytes.length}));
        await req.response.close();
        return;
      }

      req.response.statusCode = 404;
      await req.response.close();
    } catch (e) {
      try {
        req.response.statusCode = 500;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': false, 'error': '$e'}));
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 取本机局域网 IP，优先无线网卡
  static Future<String?> localIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in ifaces) {
        final n = i.name.toLowerCase();
        if (n.contains('wlan') || n.contains('ap') || n.contains('wl')) {
          for (final a in i.addresses) {
            if (!a.isLoopback) return a.address;
          }
        }
      }
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.address.startsWith('169.254')) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  static const String _page = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>岛上书店 · 传书</title>
<style>
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh;
    background: #F7F5F0; color: #2B2B2B;
    font-family: -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
    display: flex; align-items: center; justify-content: center;
    padding: 32px 20px;
  }
  .wrap { width: 100%; max-width: 560px; }
  h1 { font-size: 24px; font-weight: 600; letter-spacing: 2px; margin: 0 0 6px; }
  .sub { font-size: 13px; color: #8A8378; margin-bottom: 26px; }
  .drop {
    border: 2px dashed #C9C0B0; border-radius: 14px;
    padding: 56px 24px; text-align: center; cursor: pointer;
    background: #FFFDF9; transition: .18s;
  }
  .drop:hover, .drop.over { border-color: #7A6A58; background: #FBF6EC; }
  .drop .icon { font-size: 40px; margin-bottom: 12px; opacity: .55; }
  .drop .t { font-size: 15px; margin-bottom: 6px; }
  .drop .h { font-size: 12px; color: #8A8378; }
  input[type=file] { display: none; }
  .list { margin-top: 22px; }
  .item {
    display: flex; align-items: center; gap: 12px;
    padding: 12px 14px; background: #fff; border-radius: 10px;
    margin-bottom: 8px; font-size: 13px;
    box-shadow: 0 1px 4px rgba(60,50,40,.07);
  }
  .item .name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .item .st { font-size: 12px; color: #8A8378; flex: 0 0 auto; }
  .item .st.ok { color: #4A7A4A; }
  .item .st.err { color: #B04A4A; }
  .bar { height: 3px; background: #EDE8DF; border-radius: 2px; overflow: hidden; margin-top: 8px; }
  .bar i { display: block; height: 100%; width: 0; background: #7A6A58; transition: width .2s; }
  .tip { margin-top: 22px; font-size: 12px; color: #8A8378; line-height: 1.8; }
</style>
</head>
<body>
<div class="wrap">
  <h1>岛上书店</h1>
  <div class="sub">把 epub 拖进来，手机上会自动导入</div>

  <div class="drop" id="drop">
    <div class="icon">📚</div>
    <div class="t">拖拽文件到这里，或点击选择</div>
    <div class="h">支持 .epub / .txt，可一次选多个</div>
  </div>
  <input type="file" id="file" multiple accept=".epub,.txt">

  <div class="list" id="list"></div>

  <div class="tip">
    · 手机和电脑要在同一个 WiFi 下<br>
    · 传完手机上会自动出现在书架里<br>
    · 传完记得在手机上关掉这个服务
  </div>
</div>

<script>
const drop = document.getElementById('drop');
const input = document.getElementById('file');
const list = document.getElementById('list');

drop.addEventListener('click', () => input.click());
input.addEventListener('change', () => { upload([...input.files]); input.value = ''; });

['dragenter','dragover'].forEach(t => drop.addEventListener(t, e => {
  e.preventDefault(); drop.classList.add('over');
}));
['dragleave','drop'].forEach(t => drop.addEventListener(t, e => {
  e.preventDefault(); drop.classList.remove('over');
}));
drop.addEventListener('drop', e => {
  const files = [...e.dataTransfer.files].filter(f => /\.(epub|txt)$/i.test(f.name));
  if (files.length) upload(files);
  else alert('只能传 .epub 或 .txt 文件');
});

async function upload(files) {
  for (const f of files) {
    const row = document.createElement('div');
    row.className = 'item';
    row.innerHTML = '<span class="name"></span><span class="st">等待中</span>';
    row.querySelector('.name').textContent = f.name;
    list.appendChild(row);

    const st = row.querySelector('.st');
    st.textContent = '上传中…';

    try {
      const res = await fetch('/upload?name=' + encodeURIComponent(f.name), {
        method: 'POST',
        body: f,
      });
      const data = await res.json();
      if (data.ok) {
        st.textContent = '已导入';
        st.className = 'st ok';
      } else {
        st.textContent = data.error || '失败';
        st.className = 'st err';
      }
    } catch (e) {
      st.textContent = '网络错误';
      st.className = 'st err';
    }
  }
}
</script>
</body>
</html>''';
}
