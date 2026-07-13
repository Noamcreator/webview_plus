import 'dart:async';

/// Callback exécuté quand l'utilisateur appuie sur un [ContextMenuItem]
/// personnalisé. [selectedText] contient le texte actuellement sélectionné
/// dans la page (chaîne vide si aucune sélection, par ex. menu déclenché sur
/// une image ou un lien).
typedef ContextMenuAction = FutureOr<void> Function(String selectedText);

/// Élément personnalisé ajouté au menu contextuel natif (menu affiché lors
/// d'une sélection de texte ou d'un appui long / clic droit).
///
/// **Android et iOS uniquement** : sur desktop (Windows/macOS/Linux), le
/// clic droit ouvre le menu contextuel classique du navigateur plutôt
/// qu'une barre de sélection tactile, sans point d'extension adapté à ce
/// type d'entrée personnalisée ; ce réglage y est donc silencieusement
/// ignoré.
///
/// Entièrement géré côté plateforme native : Android ajoute l'entrée dans
/// l'`ActionMode` de sélection, iOS dans le menu contextuel long-press
/// (`UIContextMenuConfiguration`).
class ContextMenuItem {
  const ContextMenuItem({
    required this.id,
    required this.name,
    required this.action,
  });

  /// Identifiant unique de l'élément, renvoyé par le natif lorsqu'il est
  /// sélectionné afin de retrouver le bon [action].
  final String id;

  /// Libellé affiché dans le menu.
  final String name;

  /// Callback exécuté à la sélection de cet élément.
  final ContextMenuAction action;

  Map<String, dynamic> toMap() => <String, dynamic>{'id': id, 'name': name};
}

/// Éléments par défaut du menu contextuel natif (sélection de texte),
/// individuellement désactivables via
/// `WebviewSettings.disabledDefaultContextMenuItems`.
///
/// **Android et iOS uniquement**, pour la même raison que
/// [ContextMenuItem] : sans effet sur desktop.
///
/// Chaque plateforme gère elle-même la correspondance : Android retire
/// l'entrée `android.R.id.*` correspondante de l'`ActionMode`, iOS bloque
/// l'action via `canPerformAction(_:withSender:)`.
enum DefaultContextMenuItem {
  copy,
  cut,
  paste,
  selectAll,
}
