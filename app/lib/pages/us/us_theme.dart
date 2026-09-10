import 'package:flutter/material.dart';

/// SIMONSBOOKCLUB ("Us"): the visual vocabulary of the couple screens.
///
/// The one idea worth stating: each of you gets a colour, used everywhere.
/// A chip beside a factor, a rail beside a column, a line on a chart — all
/// the same two colours, so "who is this about" never needs reading.
///
/// Teal and violet, not teal and rose. Rose separates from teal at ΔE 3.9
/// under deuteranopia, which is a fail; violet separates at 15.2, and sits
/// far from the amber and coral the app already spends on status, so a
/// person's colour can never be mistaken for a warning.
class UsInk {
  UsInk._();

  // Ground and surfaces
  static const ground = Colors.black;
  static const card = Color(0xFF1F1F25);
  static const raised = Color(0xFF26262E);
  static const sheet = Color(0xFF17171C);
  static const hairline = Color(0x12FFFFFF);

  // People
  static const you = Color(0xFF4ECFC0);
  static const them = Color(0xFFA78BFA);
  static const onYou = Color(0xFF05201D);
  static const onThem = Color(0xFF1B1030);

  /// The two meeting: only where both of you are in it.
  static const sharedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [you, them],
  );

  // Status — unchanged from the rest of the app
  static const calm = Color(0xFF6FC3B8);
  static const elevated = Color(0xFFD4A64F);
  static const high = Color(0xFFE5785C);

  // Ink
  static const strong = Colors.white;
  static const body = Color(0xB8FFFFFF);
  static const label = Color(0x61FFFFFF);
  static const faint = Color(0x3DFFFFFF);

  /// The colour for a person, by whether they are the viewer.
  static Color person(bool mine) => mine ? you : them;
  static Color onPerson(bool mine) => mine ? onYou : onThem;

  static Color forLevel(String level) => switch (level) {
        'high' => high,
        'elevated' => elevated,
        'calm' => calm,
        _ => faint,
      };

  static const labelStyle = TextStyle(
    color: label,
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
  );
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
