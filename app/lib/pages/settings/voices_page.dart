import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:just_audio/just_audio.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/providers/people_provider.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB PAGE: listen to recurring voices the backend has
/// fingerprinted and give them names — the manual counterpart to wake-word
/// self-enrollment. Naming a voice retro-labels every conversation it ever
/// appeared in (server side: /omi/v1/voices/label), and the voice matcher
/// auto-resolves it in all future conversations.
class VoicesPage extends StatefulWidget {
  const VoicesPage({super.key});

  @override
  State<VoicesPage> createState() => _VoicesPageState();
}

class _Voice {
  final int id;
  final String label;
  final int timesSeen;
  final String lastSeenAt;
  final String listenUrl;

  _Voice(this.id, this.label, this.timesSeen, this.lastSeenAt, this.listenUrl);
}

class _VoicesPageState extends State<VoicesPage> {
  List<Map<String, dynamic>> _people = [];
  List<_Voice> _voices = [];
  bool _loading = true;
  int? _playingId;
  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _load();
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed && mounted) {
        setState(() => _playingId = null);
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final response = await makeApiCall(
        url: '${Env.apiBaseUrl}v1/voices',
        headers: {},
        method: 'GET',
        body: '',
      );
      if (response != null && response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final people = (data['people'] as List? ?? []).cast<Map<String, dynamic>>();
        final unidentified = (data['unidentified'] as List? ?? []).cast<Map<String, dynamic>>();
        setState(() {
          _people = people;
          _voices = unidentified
              .map((u) => _Voice(
                    (u['id'] as num).toInt(),
                    u['label'] as String? ?? 'Voice',
                    (u['times_seen'] as num?)?.toInt() ?? 0,
                    u['last_seen_at'] as String? ?? '',
                    u['listen_url'] as String? ?? '',
                  ))
              .toList();
        });
      }
    } catch (e) {
      Logger.debug('VoicesPage load failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(_Voice voice) async {
    if (_playingId == voice.id) {
      await _player.stop();
      setState(() => _playingId = null);
      return;
    }
    try {
      setState(() => _playingId = voice.id);
      await _player.setUrl(
        voice.listenUrl,
        headers: {'Authorization': 'Bearer ${SharedPreferencesUtil().authToken}'},
      );
      await _player.play();
    } catch (e) {
      Logger.debug('Voice clip playback failed: $e');
      if (mounted) {
        setState(() => _playingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No audio sample available for this voice (it may have expired)')),
        );
      }
    }
  }

  Future<void> _name(_Voice voice, {String? preset}) async {
    String? name = preset;
    if (name == null) {
      final controller = TextEditingController();
      name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F25),
          title: Text('Who is ${voice.label}?', style: const TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: 'Name', hintStyle: TextStyle(color: Colors.white38)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    }
    if (name == null || name.isEmpty) return;

    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}v1/voices/label',
      headers: {},
      method: 'POST',
      body: jsonEncode({'unknown_voice_id': voice.id, 'person_name': name}),
    );
    if (response != null && response.statusCode == 200 && mounted) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final relabeled = data['conversations_relabeled'] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name enrolled — $relabeled past sighting(s) relabeled'), backgroundColor: Colors.green),
      );
      // Refresh the app-wide people cache so the new name resolves in
      // transcripts immediately (it's loaded once at boot otherwise).
      try {
        context.read<PeopleProvider>().setPeople();
      } catch (_) {}
      _load();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save name'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Voices')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_people.isNotEmpty) ...[
                    const Text('Known voices', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 8),
                    ..._people.map((p) => Card(
                          color: const Color(0xFF1F1F25),
                          child: ListTile(
                            leading: const Icon(Icons.person, color: Colors.white70),
                            title: Text(p['person_name'] as String? ?? '?',
                                style: const TextStyle(color: Colors.white)),
                            subtitle: Text('${p['sample_count'] ?? 0} voice sample(s)',
                                style: const TextStyle(color: Colors.white38, fontSize: 12)),
                          ),
                        )),
                    const SizedBox(height: 20),
                  ],
                  const Text('Unidentified voices — tap play, then name them',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  if (_voices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No unidentified voices right now.',
                          textAlign: TextAlign.center, style: TextStyle(color: Colors.white38)),
                    ),
                  ..._voices.map((v) => Card(
                        color: const Color(0xFF1F1F25),
                        child: ListTile(
                          leading: IconButton(
                            icon: Icon(
                              _playingId == v.id ? Icons.stop_circle : Icons.play_circle,
                              color: Colors.deepPurpleAccent,
                              size: 34,
                            ),
                            onPressed: () => _play(v),
                          ),
                          title: Text(v.label, style: const TextStyle(color: Colors.white)),
                          subtitle: Text(
                            'Heard ${v.timesSeen}× · last ${v.lastSeenAt.length >= 10 ? v.lastSeenAt.substring(0, 10) : v.lastSeenAt}',
                            style: const TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(onPressed: () => _name(v, preset: 'Simon'), child: const Text('Me')),
                              TextButton(onPressed: () => _name(v), child: const Text('Name')),
                            ],
                          ),
                        ),
                      )),
                ],
              ),
            ),
    );
  }
}
