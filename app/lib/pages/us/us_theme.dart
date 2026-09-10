import 'package:flutter/material.dart';

import 'package:omi/utils/ui_guidelines.dart';

/// SIMONSBOOKCLUB ("Us"): the couple screens' names for the app's palette.
///
/// The palette itself lives in AppStyles (lib/utils/ui_guidelines.dart) and
/// is the whole app's, not this tab's — a person is the same colour on the
/// home screen's transcript as on an Us chart. These are the short names the
/// couple screens read better with, plus the two helpers that only make
/// sense where there are two of you.
class UsInk {
  UsInk._();

  // Ground and surfaces
  static const ground = AppStyles.backgroundPrimary;
  static const card = AppStyles.backgroundSecondary;
  static const raised = AppStyles.backgroundRaised;
  static const sheet = AppStyles.backgroundSheet;
  static const hairline = AppStyles.hairline;

  // People
  static const you = AppStyles.accent;
  static const them = AppStyles.partner;
  static const onYou = AppStyles.onAccent;
  static const onThem = AppStyles.onPartner;

  /// The two meeting: only where both of you are in it.
  static const sharedGradient = AppStyles.sharedGradient;

  // Status
  static const calm = AppStyles.calm;
  static const elevated = AppStyles.attention;
  static const high = AppStyles.live;

  // Ink
  static const strong = Colors.white;
  static const body = AppStyles.inkBody;
  static const label = AppStyles.inkLabel;
  static const faint = AppStyles.inkFaint;

  /// The colour for a person, by whether they are the viewer.
  static Color person(bool mine) => mine ? you : them;
  static Color onPerson(bool mine) => mine ? onYou : onThem;

  static Color forLevel(String level) => switch (level) {
        'high' => high,
        'elevated' => elevated,
        'calm' => calm,
        _ => faint,
      };

  static const labelStyle = AppStyles.sectionLabel;
}

/// A section label: small, spaced, upper case. Used once per card.
class UsLabel extends StatelessWidget {
  const UsLabel(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: UsInk.labelStyle.copyWith(color: color ?? UsInk.label),
      );
}

/// A person's name as a chip in their own colour. The whole point of the
/// redesign: you never have to read a name to know whose row this is.
class UsPersonChip extends StatelessWidget {
  const UsPersonChip(this.name, {super.key, required this.mine, this.dim = false});
  final String name;
  final bool mine;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final c = UsInk.person(mine);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: dim ? const Color(0x0FFFFFFF) : c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        name,
        style: TextStyle(
          color: dim ? UsInk.faint : c,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The initial in a filled circle. Two of them, overlapped, are the pair mark.
class UsAvatar extends StatelessWidget {
  const UsAvatar(this.name, {super.key, required this.mine, this.size = 24, this.ring = false});
  final String name;
  final bool mine;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: UsInk.person(mine),
          shape: BoxShape.circle,
          border: ring ? Border.all(color: UsInk.ground, width: 2) : null,
        ),
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: TextStyle(
            color: UsInk.onPerson(mine),
            fontSize: size * 0.44,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

/// The pair, overlapped. Used once, in the header.
class UsPairMark extends StatelessWidget {
  const UsPairMark({super.key, required this.you, required this.them, this.size = 30});
  final String you;
  final String them;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size * 1.53,
        height: size,
        child: Stack(children: [
          Positioned(left: 0, child: UsAvatar(you, mine: true, size: size)),
          Positioned(left: size * 0.53, child: UsAvatar(them, mine: false, size: size, ring: true)),
        ]),
      );
}

/// The card everything sits in.
class UsCard extends StatelessWidget {
  const UsCard({super.key, required this.children, this.padding, this.border});
  final List<Widget> children;
  final EdgeInsets? padding;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding ?? const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: UsInk.card,
          borderRadius: BorderRadius.circular(18),
          border: border == null ? null : Border.all(color: border!),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}
