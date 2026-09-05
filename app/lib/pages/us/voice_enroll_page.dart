import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/http/api/us.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/providers/us_provider.dart';
import 'package:omi/services/us_session.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB ("Us"): enroll a voice by reading a passage for thirty
/// seconds into the phone microphone. The recording goes to the worker as
/// raw 16 kHz PCM, is fingerprinted on Modal and folded into the caller's
/// voiceprint, which is what lets the pendant know who is speaking.
class VoiceEnrollPage extends StatefulWidget {
  const VoiceEnrollPage({super.key});

  @override
  State<VoiceEnrollPage> createState() => _VoiceEnrollPageState();
}

const _passage = '''I am reading this so the app can learn my voice. It listens for the way I speak, not for what I say, so the words do not matter much.

We bought bread on the way home and the bakery had run out of the seeded loaf, so we took the plain one and argued, gently, about whether that counted as a loss. The sea was flat and grey and there were three boats far out, or maybe four; one kept disappearing behind the swell.

Tomorrow I would like to sleep late, drink coffee slowly, and walk somewhere with no plan. That is enough for the app to remember me by. Thank you for listening.''';

class _VoiceEnrollPageState extends State<VoiceEnrollPage> {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _ready = false;
  bool _recording = false;
  bool _uploading = false;
  int _seconds = 0;
  String? _path;
  String? _message;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() => _message = 'Microphone permission is needed to record.');
      return;
    }
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 500));
    _recorder.onProgress?.listen((e) {
      if (mounted) setState(() => _seconds = e.duration.inSeconds);
    });
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _recorder.closeRecorder();
    super.dispose();
  }

  Future<void> _start() async {
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/voice_enroll_${DateTime.now().millisecondsSinceEpoch}.pcm';
    await _recorder.startRecorder(toFile: _path, codec: Codec.pcm16, sampleRate: 16000, numChannels: 1);
    setState(() { _recording = true; _seconds = 0; _message = null; });
  }

  Future<void> _stop() async {
    await _recorder.stopRecorder();
    setState(() => _recording = false);
    if (_seconds < 10) {
      setState(() => _message = 'That was under ten seconds. Read the whole passage.');
      return;
    }
    await _upload();
  }

  Future<void> _upload() async {
    final path = _path;
    if (path == null) return;
    setState(() { _uploading = true; _message = null; });
    try {
      await UsSession.ensureSession();
      final bytes = await File(path).readAsBytes();
      final auth = await getAuthHeader();
      final res = await http.post(
        Uri.parse('${Env.apiBaseUrl}v1/us/voice/enroll'),
        headers: {'Authorization': auth, 'Content-Type': 'audio/L16', ...UsApi.actHeaders},
        body: bytes,
      );
      final body = res.body;
      if (res.statusCode != 200) {
        final err = RegExp(r'"error":"([^"]+)"').firstMatch(body)?.group(1) ?? 'Upload failed (${res.statusCode})';
        setState(() => _message = err);
        return;
      }
      final voice = RegExp(r'"voice":"([^"]+)"').firstMatch(body)?.group(1) ?? 'you';
      final samples = RegExp(r'"samples":(\d+)').firstMatch(body)?.group(1) ?? '1';
      setState(() { _done = true; _message = 'Your voice is "$voice" ($samples sample${samples == '1' ? '' : 's'}). Read it again another day to make it stronger.'; });
      if (mounted) {
        context.read<UsProvider>().loadAccount();
        context.read<UsProvider>().refresh(force: true);
      }
    } catch (e) {
      Logger.debug('voice enroll failed: $e');
      setState(() => _message = 'Upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Your voice')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('${UsApi.actAs != null ? 'Hand the phone over. ' : ''}Read this aloud, at your normal pace, somewhere quiet. About thirty seconds.', style: const TextStyle(color: Colors.white70, height: 1.4)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: const Color(0xFF1F1F25), borderRadius: BorderRadius.circular(16)),
                  child: const Text(_passage, style: TextStyle(color: Colors.white, fontSize: 19, height: 1.55)),
                ),
                if (_message != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_message!, style: TextStyle(color: _done ? const Color(0xFF6FC3B8) : const Color(0xFFE5785C), height: 1.4))),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            decoration: const BoxDecoration(color: Color(0xFF141418), borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            child: Column(children: [
              Text(_recording ? '${_seconds}s' : (_uploading ? 'Fingerprinting…' : (_done ? 'Done' : 'Ready')), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w300)),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: _recording ? const Color(0xFFE5785C) : Colors.white, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: !_ready || _uploading ? null : (_recording ? _stop : (_done ? () => Navigator.of(context).pop() : _start)),
                  child: Text(_recording ? 'Stop and send' : (_done ? 'Close' : 'Start recording')),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
