import 'package:shared_preferences/shared_preferences.dart';

/// Preferencias locales no sensibles del usuario (la bolsa elegida, por ahora). Separada de
/// `TokenStorage`, que usa el keychain/keystore nativo porque guarda el JWT — un setting de
/// UI no necesita ese costo ni esa garantía.
///
/// Lee/escribe la instancia de `SharedPreferences` de forma perezosa y la cachea: obtenerla
/// es asíncrono (I/O) y no tiene sentido repetirlo en cada acceso.
class PreferencesStorage {
  PreferencesStorage({SharedPreferences? preferences}) : _cached = preferences;

  static const _selectedExchangeKey = 'financiero_selected_exchange';

  SharedPreferences? _cached;

  Future<SharedPreferences> _instance() async =>
      _cached ??= await SharedPreferences.getInstance();

  Future<String?> readSelectedExchange() async =>
      (await _instance()).getString(_selectedExchangeKey);

  Future<void> saveSelectedExchange(String wireValue) async {
    await (await _instance()).setString(_selectedExchangeKey, wireValue);
  }

  Future<void> clearSelectedExchange() async {
    await (await _instance()).remove(_selectedExchangeKey);
  }
}
