import 'package:flutter/material.dart';


/// UI Guidelines to ensure consistent styling throughout the app
/// Use this class for reference when creating new UI components
class AppStyles {
  // Text Styles
  static const TextStyle title = TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white);

  static const TextStyle subtitle = TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white);

  static const TextStyle body = TextStyle(fontSize: 15, height: 1.4, color: Colors.white);

  static const TextStyle caption = TextStyle(fontSize: 14, color: Colors.white70);

  static const TextStyle small = TextStyle(fontSize: 12, color: Colors.white70);

  static const TextStyle label = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white70);

  // Colors
  static const Color backgroundPrimary = Colors.black;
  static const Color backgroundSecondary = Color(0xFF1F1F25);


  static const Color textPrimary = Colors.white;
  static final Color textSecondary = Colors.white.withValues(alpha: 0.8);
  static final Color textTertiary = Colors.white.withValues(alpha: 0.6);

  // --- Chronicle palette -------------------------------------------------
  //
  // One idea holds the app together: a person is a colour. Teal is you and
  // violet is Masha, on an Us chart, on a factor chip, on a line of live
  // transcript alike, so you never read a name to know whose row it is.
  //
  // Teal and rose was the obvious pairing for a couple and was dropped: it
  // separates at deuteranopia dE 3.9, which is a fail. Violet separates at
  // 15.2 and sits far from the two status colours, so a person can never be
  // mistaken for a warning.
  //
  // This replaces Omi's #7B5CFF -> #5733E0 purple, which was the forked
  // app's brand and collided with the violet that now means a person.

  /// You. The app's accent everywhere, and your half of any pair.
  static const Color accent = Color(0xFF4ECFC0);
  static const Color onAccent = Color(0xFF05201D);

  /// Your partner. Reserved — never spent on a fourth series or a button.
  static const Color partner = Color(0xFFA78BFA);
  static const Color onPartner = Color(0xFF1B1030);

  /// Happening now, or about to hurt: recording, high risk, ending something.
  static const Color live = Color(0xFFE5785C);

  /// Worth a look, not yet wrong.
  static const Color attention = Color(0xFFD4A64F);

  /// Settled, restored, calm.
  static const Color calm = Color(0xFF6FC3B8);

  /// A control sitting on top of a card.
  static const Color backgroundRaised = Color(0xFF26262E);

  /// #35343B. Do NOT collapse this into `backgroundRaised` — it was tried on
  /// 2026-09-10 and reverted the same day. Tertiary is not only a control
  /// fill: it is the border on the chat input, the hairlines inside the score
  /// card, the unfilled half of every progress track, the highlight of
  /// fourteen shimmer skeletons, and `colorScheme.secondary`, which under
  /// Material 2 is the "on" colour of every Switch without an explicit one.
  /// Against #1F1F25 it carries 1.33:1; #26262E carries 1.09:1, which erases
  /// all of them.
  static const Color backgroundTertiary = Color(0xFF35343B);

  /// A sheet, which sits above everything.
  static const Color backgroundSheet = Color(0xFF17171C);

  /// Separates rows inside a card. Nothing else draws a border unless it is
  /// carrying a state.
  static const Color hairline = Color(0x12FFFFFF);

  /// Present but not the point.
  static const Color inkFaint = Color(0x3DFFFFFF);

  /// Metadata beside a title: a time, a duration, a count. Dimmer than body
  /// text, brighter than a label, because it is still read.
  static const Color inkMeta = Color(0x99FFFFFF);
  static const Color inkLabel = Color(0x61FFFFFF);
  static const Color inkBody = Color(0xB8FFFFFF);

  static final Color error = Colors.red.shade800;
  static final Color success = Colors.green.shade600;

  /// The two meeting. Only where both of you are in it.
  static const LinearGradient sharedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, partner],
  );

  /// A section label: one per section, never two.
  static const TextStyle sectionLabel = TextStyle(
    color: inkLabel,
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
  );

  /// The screen's subject, used once at the top.
  static const TextStyle screenTitle =
      TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.7, height: 1.1);

  /// A card's headline.
  static const TextStyle cardTitle =
      TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w600, letterSpacing: -0.2);

  /// A row's title, and the line under it.
  static const TextStyle rowTitle = TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w600);
  static const TextStyle rowSubtitle = TextStyle(color: Color(0x80FFFFFF), fontSize: 13, height: 1.4);

  // Spacing
  static const double spacingXS = 4.0;
  static const double spacingS = 8.0;
  static const double spacingM = 12.0;
  static const double spacingL = 16.0;
  static const double spacingXL = 24.0;
  static const double spacingXXL = 32.0;

  // Radius. Four values with a rule, rather than four values.
  static const double radiusSmall = 7.0; // a chip or a checkbox
  static const double radiusMedium = 12.0; // a control inside a card
  static const double radiusLarge = 18.0; // a card
  static const double radiusCircular = 999.0; // a pill

  // Widget specific
  // A card is a flat surface, not a floating one: a shadow on a #1F1F25 card
  // over a black ground renders as a smudge and buys no separation.
  static final cardDecoration = BoxDecoration(
    color: backgroundSecondary,
    borderRadius: BorderRadius.circular(radiusLarge),
  );

  static final inputDecoration = InputDecoration(
    filled: true,
    fillColor: backgroundTertiary,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusMedium), borderSide: BorderSide.none),
  );

  static final chipDecoration = BoxDecoration(
    color: backgroundTertiary.withValues(alpha: 0.6),
    borderRadius: BorderRadius.circular(radiusCircular),
  );
}

/// Theme extension to provide app styles as part of the theme
class AppTheme extends ThemeExtension<AppTheme> {
  final TextStyle title;
  final TextStyle subtitle;
  final TextStyle body;
  final TextStyle caption;
  final TextStyle small;
  final TextStyle label;

  AppTheme({
    required this.title,
    required this.subtitle,
    required this.body,
    required this.caption,
    required this.small,
    required this.label,
  });

  @override
  ThemeExtension<AppTheme> copyWith({
    TextStyle? title,
    TextStyle? subtitle,
    TextStyle? body,
    TextStyle? caption,
    TextStyle? small,
    TextStyle? label,
  }) {
    return AppTheme(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      body: body ?? this.body,
      caption: caption ?? this.caption,
      small: small ?? this.small,
      label: label ?? this.label,
    );
  }

  @override
  ThemeExtension<AppTheme> lerp(ThemeExtension<AppTheme>? other, double t) {
    if (other is! AppTheme) {
      return this;
    }
    return AppTheme(
      title: TextStyle.lerp(title, other.title, t)!,
      subtitle: TextStyle.lerp(subtitle, other.subtitle, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      caption: TextStyle.lerp(caption, other.caption, t)!,
      small: TextStyle.lerp(small, other.small, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
    );
  }

  /// Apply AppTheme to ThemeData
  static ThemeData applyToTheme(ThemeData theme) {
    return theme.copyWith(
      extensions: [
        AppTheme(
          title: AppStyles.title,
          subtitle: AppStyles.subtitle,
          body: AppStyles.body,
          caption: AppStyles.caption,
          small: AppStyles.small,
          label: AppStyles.label,
        ),
      ],
    );
  }
}
