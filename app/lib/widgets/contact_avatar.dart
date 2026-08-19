import 'package:flutter/material.dart';

import 'package:omi/services/contacts_link_service.dart';

/// SIMONSBOOKCLUB: a speaker's iOS contact photo, if they've been linked to
/// a contact card. Falls back to [fallback] — the app's generated avatar —
/// whenever there is no link, no photo, or no Contacts permission, so
/// callers can drop this in without branching.
class ContactAvatar extends StatefulWidget {
  final String? speakerName;
  final double size;
  final Widget fallback;

  const ContactAvatar({super.key, required this.speakerName, required this.size, required this.fallback});

  @override
  State<ContactAvatar> createState() => _ContactAvatarState();
}

class _ContactAvatarState extends State<ContactAvatar> {
  @override
  void initState() {
    super.initState();
    _warm();
  }

  @override
  void didUpdateWidget(covariant ContactAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speakerName != widget.speakerName) _warm();
  }

  void _warm() {
    final name = widget.speakerName;
    final service = ContactsLinkService();
    if (name == null || name.isEmpty) return;
    if (service.hasFetched(name)) return;
    if (!service.isLinked(name)) return;
    service.warmThumbnail(name).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.speakerName;
    final bytes = name == null ? null : ContactsLinkService().cachedThumbnailFor(name);
    if (bytes == null) return widget.fallback;
    return ClipOval(
      child: Image.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => widget.fallback,
      ),
    );
  }
}
