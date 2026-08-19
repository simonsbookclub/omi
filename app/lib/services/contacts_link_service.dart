import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';

/// SIMONSBOOKCLUB: links identified speakers to iOS contact cards so
/// transcripts show real faces instead of generated avatars.
///
/// Everything stays on the phone: only `speaker name -> contact identifier`
/// is persisted (SharedPreferences), and the photo is re-read from the iOS
/// Contacts store each session. No contact data is ever sent to the
/// backend, which is why the mapping lives here rather than beside the
/// voiceprints.
class ContactLink {
  final String identifier;
  final String name;
  final bool hasImage;

  const ContactLink({required this.identifier, required this.name, required this.hasImage});
}

class ContactsLinkService {
  static const _channel = MethodChannel('com.simonsbookclub.contacts');
  static const _prefsKey = 'speakerContactLinks';

  static final ContactsLinkService _instance = ContactsLinkService._internal();
  factory ContactsLinkService() => _instance;
  ContactsLinkService._internal();

  /// speaker name (lowercased) -> contact identifier
  Map<String, String> _links = {};
  bool _loaded = false;

  /// contact identifier -> decoded thumbnail. Populated on demand and kept
  /// for the session: transcripts rebuild constantly and each rebuild would
  /// otherwise cross the method channel per bubble.
  final Map<String, Uint8List?> _thumbnails = {};

  bool get isAvailable => PlatformService.isApple;

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = SharedPreferencesUtil().getString(_prefsKey);
      if (raw.isNotEmpty) {
        _links = Map<String, String>.from(jsonDecode(raw) as Map);
      }
    } catch (e) {
      Logger.debug('ContactsLinkService: failed to load links: $e');
      _links = {};
    }
  }

  void _persist() {
    SharedPreferencesUtil().saveString(_prefsKey, jsonEncode(_links));
  }

  Future<bool> hasAccess() async {
    if (!isAvailable) return false;
    try {
      return await _channel.invokeMethod('hasAccess') == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestAccess() async {
    if (!isAvailable) return false;
    try {
      return await _channel.invokeMethod('requestAccess') == true;
    } catch (e) {
      Logger.debug('ContactsLinkService: requestAccess failed: $e');
      return false;
    }
  }

  Future<List<ContactLink>> listContacts() async {
    if (!isAvailable) return [];
    try {
      final result = await _channel.invokeMethod('listContacts');
      if (result is! List) return [];
      return result
          .map((e) => Map<String, dynamic>.from(e as Map))
          .map((m) => ContactLink(
                identifier: m['identifier'] as String? ?? '',
                name: m['name'] as String? ?? '',
                hasImage: m['hasImage'] == true,
              ))
          .where((c) => c.identifier.isNotEmpty && c.name.isNotEmpty)
          .toList();
    } catch (e) {
      Logger.debug('ContactsLinkService: listContacts failed: $e');
      return [];
    }
  }

  String? identifierFor(String speakerName) {
    _ensureLoaded();
    return _links[speakerName.trim().toLowerCase()];
  }

  bool isLinked(String speakerName) => identifierFor(speakerName) != null;

  void link(String speakerName, String contactIdentifier) {
    _ensureLoaded();
    _links[speakerName.trim().toLowerCase()] = contactIdentifier;
    _persist();
  }

  void unlink(String speakerName) {
    _ensureLoaded();
    _links.remove(speakerName.trim().toLowerCase());
    _thumbnails.clear();
    _persist();
  }

  /// Cached thumbnail for a linked speaker, or null when unlinked, denied,
  /// or the contact has no photo. Synchronous read of the session cache —
  /// call [warmThumbnail] first from an async context.
  Uint8List? cachedThumbnailFor(String speakerName) {
    final id = identifierFor(speakerName);
    if (id == null) return null;
    return _thumbnails[id];
  }

  bool hasFetched(String speakerName) {
    final id = identifierFor(speakerName);
    return id != null && _thumbnails.containsKey(id);
  }

  Future<Uint8List?> warmThumbnail(String speakerName) async {
    final id = identifierFor(speakerName);
    if (id == null || !isAvailable) return null;
    if (_thumbnails.containsKey(id)) return _thumbnails[id];
    try {
      final b64 = await _channel.invokeMethod('getThumbnail', {'identifier': id});
      final bytes = b64 is String && b64.isNotEmpty ? base64Decode(b64) : null;
      // Cache the null too — a photo-less contact must not re-cross the
      // channel on every transcript rebuild.
      _thumbnails[id] = bytes;
      return bytes;
    } catch (e) {
      Logger.debug('ContactsLinkService: getThumbnail failed: $e');
      _thumbnails[id] = null;
      return null;
    }
  }
}
