import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';

/// Simple utility to generate a random session token.
/// In a production app, you might use the `uuid` package instead.
String _randomSessionToken() {
  final random = Random();
  return List.generate(20, (_) => random.nextInt(10)).join();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // await dotenv.load(fileName: ".env");
  runApp(const MaterialApp(
    home: GoogleMapPage(),
    debugShowCheckedModeBanner: false,
  ));
}

class GoogleMapPage extends StatefulWidget {
  const GoogleMapPage({Key? key}) : super(key: key);

  @override
  State<GoogleMapPage> createState() => _GoogleMapPageState();
}

class _GoogleMapPageState extends State<GoogleMapPage> {
  // Location & Map
  final Location _locationService = Location();
  GoogleMapController? _mapController;
  static const LatLng _plmIntramuros = LatLng(14.5880, 120.9740);
  LatLng _currentPosition = _plmIntramuros;

  // Markers & Polylines
  LatLng? _startPoint;
  LatLng? _endPoint;
  final Set<Marker> _markers = {};
  final Map<PolylineId, Polyline> _polylines = {};
  double _totalDistance = 0.0;

  // Load from .env or just hard-code your key here
  final String _baseUrl = 'http://10.0.2.2:8080';
  final String _apiKey = 'Lagay mo API'; // replace with your own key

  // Settings
  int _defaultK = 5;
  bool _trafficEnabled = false;

  // Controllers for search fields
  final TextEditingController _startController = TextEditingController();
  final TextEditingController _endController = TextEditingController();

  // Suggestion lists
  List<dynamic> _startSuggestions = [];
  List<dynamic> _endSuggestions = [];

  // Session tokens for Google Places Autocomplete
  String? _startSessionToken;
  String? _endSessionToken;

  // Loading message for overlay
  String? _loadingMessage;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _checkPermissions();
    try {
      final loc = await _locationService.getLocation();
      if (loc.latitude != null && loc.longitude != null) {
        _currentPosition = LatLng(loc.latitude!, loc.longitude!);
      }
    } catch (_) {}
    _locationService.onLocationChanged.listen((loc) {
      if (loc.latitude != null && loc.longitude != null) {
        setState(() {
          _currentPosition = LatLng(loc.latitude!, loc.longitude!);
        });
      }
    });
  }

  Future<void> _checkPermissions() async {
    bool serviceEnabled = await _locationService.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await _locationService.requestService();
      if (!serviceEnabled) throw Exception("Location services disabled");
    }
    PermissionStatus permission = await _locationService.hasPermission();
    if (permission == PermissionStatus.denied) {
      permission = await _locationService.requestPermission();
      if (permission != PermissionStatus.granted) {
        throw Exception("Location permission denied");
      }
    }
  }

  Future<void> _goToCurrentLocation() async {
    try {
      final loc = await _locationService.getLocation();
      final pos = (loc.latitude != null && loc.longitude != null)
          ? LatLng(loc.latitude!, loc.longitude!)
          : _plmIntramuros;
      setState(() => _currentPosition = pos);
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: pos, zoom: 18),
        ),
      );
    } catch (_) {
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          const CameraPosition(target: _plmIntramuros, zoom: 18),
        ),
      );
    }
  }

  /// Fetch suggestions from Google Places Autocomplete API.
  Future<List<dynamic>> _fetchSuggestions(String input,
      {String? sessionToken}) async {
    if (input.isEmpty) return [];
    final params = {
      'input': input,
      'key': _apiKey,
      'components': 'country:ph',
      'sessiontoken': sessionToken ?? '',
    };
    final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', params);
    final resp = await http.get(uri);
    if (resp.statusCode != 200) return [];
    final data = json.decode(resp.body);
    if (data['status'] != 'OK' || data['predictions'] == null) {
      return [];
    }
    return data['predictions'];
  }

  /// Geocode an address string to a LatLng using the Google Geocoding API.
  Future<LatLng?> _geocode(String address) async {
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      {
        'address': address,
        'key': _apiKey,
      },
    );
    final resp = await http.get(uri);
    if (resp.statusCode != 200) return null;
    final data = json.decode(resp.body);
    if (data['status'] != 'OK' || data['results'].isEmpty) return null;
    final loc = data['results'][0]['geometry']['location'];
    return LatLng(loc['lat'], loc['lng']);
  }

  Future<void> _searchAndMark({
    required String text,
    required bool isStart,
  }) async {
    if (text.isEmpty) return;
    final coord = await _geocode(text);
    if (coord == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not find location: "$text"')),
      );
      return;
    }
    setState(() {
      final id = isStart ? 'start' : 'end';
      final markerId = MarkerId(id);
      _markers.removeWhere((m) => m.markerId == markerId);
      _markers.add(Marker(
        markerId: markerId,
        position: coord,
        infoWindow: InfoWindow(title: isStart ? 'Start' : 'End'),
      ));
      if (isStart) {
        _startPoint = coord;
      } else {
        _endPoint = coord;
      }
    });
    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(coord, 16),
    );
  }

  Future<void> _drawRoute() async {
    if (_startPoint == null || _endPoint == null) return;
    final s = "${_startPoint!.latitude},${_startPoint!.longitude}";
    final e = "${_endPoint!.latitude},${_endPoint!.longitude}";
    final uri = Uri.parse(
      "$_baseUrl/route?start=$s&end=$e&k=$_defaultK&traffic=${_trafficEnabled ? 1 : 0}",
    );
    try {
      // Show fetching message
      setState(() {
        _loadingMessage = "Fetching shortest route...";
      });

      // Create an HTTP client and log the time before the request
      final client = http.Client();
      final fetchStart = DateTime.now();
      final resp = await client.get(uri);
      final fetchDuration = DateTime.now().difference(fetchStart);
      debugPrint("HTTP GET duration: $fetchDuration");
      client.close();

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final encoded = data["polyline"] as String?;
        final dist = (data["total_distance_km"] as num).toDouble();
        if (encoded != null) {
          // Change message before rendering the polyline
          setState(() {
            _loadingMessage = "Rendering route on map...";
          });
          final pts = await compute(_decodePolyline, encoded);
          final id = const PolylineId("route");
          final pl = Polyline(
            polylineId: id,
            color: Colors.blueAccent,
            width: 5,
            points: pts,
          );
          setState(() {
            _polylines
              ..clear()
              ..[id] = pl;
            _totalDistance = dist;
            _loadingMessage = null; // Finished rendering
          });
        }
      } else {
        setState(() {
          _loadingMessage = null;
        });
      }
    } catch (e) {
      debugPrint("Error drawing route: $e");
      setState(() {
        _loadingMessage = null;
      });
    }
  }

  static List<LatLng> _decodePolyline(String encoded) {
    final poly = PolylinePoints().decodePolyline(encoded);
    return poly.map((p) => LatLng(p.latitude, p.longitude)).toList();
  }

  /// Widget for search bar with suggestions.
  Widget _buildSearchBar({
    required TextEditingController controller,
    required String hint,
    required VoidCallback onSearch,
    required List<dynamic> suggestions,
    required Function(String) onChanged,
    required VoidCallback onClearSuggestions,
    required Function(String) onSuggestionTap,
    required bool isStart,
  }) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.search, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: hint,
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: (value) {
                    if (isStart && _startSessionToken == null) {
                      _startSessionToken = _randomSessionToken();
                    } else if (!isStart && _endSessionToken == null) {
                      _endSessionToken = _randomSessionToken();
                    }
                    onChanged(value);
                  },
                  onSubmitted: (_) {
                    onSearch();
                    onClearSuggestions();
                  },
                ),
              ),
              if (controller.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      controller.clear();
                      onClearSuggestions();
                    });
                  },
                  child: const Icon(Icons.clear, color: Colors.grey),
                ),
            ],
          ),
        ),
        if (suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: suggestions.length,
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                final mainText = suggestion['structured_formatting']
                        ?['main_text'] ??
                    suggestion['description'] ??
                    '';
                final secondaryText = suggestion['structured_formatting']
                        ?['secondary_text'] ??
                    '';
                return ListTile(
                  leading: const Icon(Icons.location_on, color: Colors.grey),
                  title: Text(
                    mainText,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(secondaryText),
                  onTap: () {
                    onSuggestionTap(suggestion['description']);
                    onClearSuggestions();
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  /// Trip button: Ensures both start and end are set, then draws route.
  Future<void> _startTrip() async {
    if (_startController.text.isEmpty || _endController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both start and end locations.')),
      );
      return;
    }
    await _searchAndMark(text: _startController.text, isStart: true);
    await _searchAndMark(text: _endController.text, isStart: false);
    await _drawRoute();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Route Planner")),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text(
                "Settings",
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),
            ListTile(
              title: const Text("Default k‑value"),
              subtitle: Text("$_defaultK"),
              trailing: SizedBox(
                width: 150,
                child: Slider(
                  value: _defaultK.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: "$_defaultK",
                  onChanged: (v) => setState(() => _defaultK = v.round()),
                ),
              ),
            ),
            SwitchListTile(
              title: const Text("Show Traffic"),
              value: _trafficEnabled,
              onChanged: (v) => setState(() => _trafficEnabled = v),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text("About"),
              onTap: () {
                showAboutDialog(
                  context: context,
                  applicationName: "Route Planner",
                  children: const [
                    Text("K‑step lookahead A* on OSM + traffic data.")
                  ],
                );
              },
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _currentPosition, zoom: 13),
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            trafficEnabled: _trafficEnabled,
            markers: _markers,
            polylines: _polylines.values.toSet(),
            onMapCreated: (c) {
              _mapController = c;
              _mapController!.moveCamera(CameraUpdate.newLatLng(_currentPosition));
            },
          ),
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Column(
              children: [
                _buildSearchBar(
                  controller: _startController,
                  hint: 'Search start location',
                  onSearch: () => _searchAndMark(
                    text: _startController.text,
                    isStart: true,
                  ),
                  suggestions: _startSuggestions,
                  onChanged: (value) async {
                    if (value.isNotEmpty) {
                      final suggestions = await _fetchSuggestions(
                        value,
                        sessionToken: _startSessionToken,
                      );
                      setState(() {
                        _startSuggestions = suggestions;
                      });
                    } else {
                      setState(() {
                        _startSuggestions = [];
                      });
                    }
                  },
                  onClearSuggestions: () {
                    setState(() {
                      _startSuggestions = [];
                      _startSessionToken = null;
                    });
                  },
                  onSuggestionTap: (suggestion) {
                    setState(() {
                      _startController.text = suggestion;
                    });
                    _searchAndMark(text: suggestion, isStart: true);
                  },
                  isStart: true,
                ),
                const SizedBox(height: 8),
                _buildSearchBar(
                  controller: _endController,
                  hint: 'Search end location',
                  onSearch: () => _searchAndMark(
                    text: _endController.text,
                    isStart: false,
                  ),
                  suggestions: _endSuggestions,
                  onChanged: (value) async {
                    if (value.isNotEmpty) {
                      final suggestions = await _fetchSuggestions(
                        value,
                        sessionToken: _endSessionToken,
                      );
                      setState(() {
                        _endSuggestions = suggestions;
                      });
                    } else {
                      setState(() {
                        _endSuggestions = [];
                      });
                    }
                  },
                  onClearSuggestions: () {
                    setState(() {
                      _endSuggestions = [];
                      _endSessionToken = null;
                    });
                  },
                  onSuggestionTap: (suggestion) {
                    setState(() {
                      _endController.text = suggestion;
                    });
                    _searchAndMark(text: suggestion, isStart: false);
                  },
                  isStart: false,
                ),
              ],
            ),
          ),
          Positioned(
            right: 16,
            bottom: 100,
            child: FloatingActionButton(
              onPressed: _goToCurrentLocation,
              child: const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 100,
            child: FloatingActionButton(
              backgroundColor: Colors.orange,
              onPressed: _drawRoute,
              child: const Icon(Icons.refresh),
            ),
          ),
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton.icon(
                onPressed: _startTrip,
                icon: const Icon(Icons.directions),
                label: const Text("Trip"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
          Positioned(
            top: 100,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "Distance: ${_totalDistance.toStringAsFixed(2)} km",
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          if (_loadingMessage != null)
            Positioned.fill(
              child: Container(
                color: Colors.black45,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _loadingMessage!,
                        style: const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
