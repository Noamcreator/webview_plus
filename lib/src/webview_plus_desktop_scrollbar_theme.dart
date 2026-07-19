import 'package:flutter/painting.dart' show Color;
import 'webview_plus_settings.dart' show DesktopScrollbarThemeMode;

/// Regroupe la configuration des barres de défilement sous Windows/macOS/Linux.
class DesktopScrollbarTheme {
  const DesktopScrollbarTheme({
    this.themeMode = DesktopScrollbarThemeMode.auto,
    this.trackColor,
    this.thumbColor,
    this.thumbHoverColor,
    this.width = 12,
  });

  /// Mode de colorisation (auto, light, dark, custom, hidden).
  final DesktopScrollbarThemeMode themeMode;

  /// Couleur de la piste (uniquement en mode `custom`).
  final Color? trackColor;

  /// Couleur du curseur au repos (uniquement en mode `custom`).
  final Color? thumbColor;

  /// Couleur du curseur au survol (uniquement en mode `custom`).
  final Color? thumbHoverColor;

  /// Épaisseur des barres de défilement en pixels CSS.
  final double width;

  /// Sérialise l'objet pour l'envoi au canal natif (MethodChannel).
  Map<String, dynamic> toMap() => <String, dynamic>{
        'themeMode': themeMode.name,
        'trackColor': trackColor?.toARGB32(),
        'thumbColor': thumbColor?.toARGB32(),
        'thumbHoverColor': thumbHoverColor?.toARGB32(),
        'width': width,
      };
}