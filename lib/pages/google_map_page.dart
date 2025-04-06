import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:intl/intl.dart';

String _randomSessionToken() {
  final random = Random();
  return List.generate(20, (_) => random.nextInt(10)).join();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final Location _locationService = Location();
  GoogleMapController? _mapController;
  static const LatLng _plmIntramuros = LatLng(14.5880, 120.9740);
  LatLng _currentPosition = _plmIntramuros;
  Marker? _userLocationMarker;

  LatLng? _startPoint;
  LatLng? _endPoint;
  final Set<Marker> _markers = {};
  final Map<PolylineId, Polyline> _polylines = {};
  double _totalDistance = 0.0;
  double _remainingDistance = 0.0;
  List<LatLng> _routePoints = [];

  bool _isNavigating = false;
  bool _hasDirections = false;
  bool _showStartTripButton = true;  // New toggle for Start Trip button
  double _heading = 0.0;
  double _currentSpeed = 0.0;
  DateTime? _estimatedArrivalTime;
  LocationData? _lastLocation;
  int _currentStep = 0;
  Timer? _navigationUpdateTimer;

  final String _baseUrl = 'http://10.0.2.2:8080';
  final String _apiKey = 'AIzaSyC4p3TtbAEeAPTzmw0Xy3bZ4FU8JybfNmU';

  int _defaultK = 5;
  bool _trafficEnabled = false;

  final TextEditingController _startController = TextEditingController();
  final TextEditingController _endController = TextEditingController();

  List<dynamic> _startSuggestions = [];
  List<dynamic> _endSuggestions = [];

  String? _startSessionToken;
  String? _endSessionToken;

  String? _loadingMessage;

  Timer? _startDebounceTimer;
  Timer? _endDebounceTimer;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _startDebounceTimer?.cancel();
    _endDebounceTimer?.cancel();
    _navigationUpdateTimer?.cancel();
    _startController.dispose();
    _endController.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  void _clearEverything() {
    setState(() {
      _markers.clear();
      _userLocationMarker = null;
      _startPoint = null;
      _endPoint = null;
      _polylines.clear();
      _totalDistance = 0.0;
      _remainingDistance = 0.0;
      _startController.clear();
      _endController.clear();
      _startSuggestions = [];
      _endSuggestions = [];
      _startSessionToken = null;
      _endSessionToken = null;
      _isNavigating = false;
      _hasDirections = false;
      _routePoints = [];
    });
    _navigationUpdateTimer?.cancel();
  }

  Future<void> _initialize() async {
    await _checkPermissions();
    try {
      final loc = await _locationService.getLocation();
      if (loc.latitude != null && loc.longitude != null) {
        _updateUserPosition(LatLng(loc.latitude!, loc.longitude!));
      }
    } catch (_) {}
    
    _locationService.changeSettings(
      accuracy: LocationAccuracy.high,
      interval: 1000,
      distanceFilter: 5,
    );
    
    _locationService.onLocationChanged.listen((loc) {
      if (loc.latitude != null && loc.longitude != null) {
        _updateUserPosition(LatLng(loc.latitude!, loc.longitude!));
      }
    });
  }

  void _updateUserPosition(LatLng position) {
    setState(() {
      _currentPosition = position;
      _userLocationMarker = Marker(
        markerId: const MarkerId('current_location'),
        position: position,
        rotation: _heading,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: const InfoWindow(title: 'Your Location'),
      );

      if (_isNavigating) {
        _updateRemainingDistance();
        _checkRouteDeviation();
      }
    });

    if (_isNavigating) {
      _updateCameraForNavigation();
    }
  }

  void _updateRemainingDistance() {
    if (_routePoints.isEmpty || _endPoint == null) return;

    double remaining = 0.0;
    int closestIndex = 0;
    double minDistance = double.infinity;

    for (int i = 0; i < _routePoints.length; i++) {
      final distance = _calculateDistance(_currentPosition, _routePoints[i]);
      if (distance < minDistance) {
        minDistance = distance;
        closestIndex = i;
      }
    }

    for (int i = closestIndex; i < _routePoints.length - 1; i++) {
      remaining += _calculateDistance(_routePoints[i], _routePoints[i + 1]);
    }

    remaining += minDistance;

    setState(() {
      _remainingDistance = remaining;
      _updateETA();
    });
  }

  void _startNavigationUpdates() {
    _navigationUpdateTimer?.cancel();
    _navigationUpdateTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_isNavigating) {
        _checkRouteDeviation();
      }
    });
  }

  void _checkRouteDeviation() {
    if (_routePoints.isEmpty || _endPoint == null) return;

    double minDistance = double.infinity;
    
    for (final point in _routePoints) {
      final distance = _calculateDistance(_currentPosition, point);
      if (distance < minDistance) {
        minDistance = distance;
      }
    }

    if (minDistance > 0.1) {
      _recalculateRouteFromCurrentPosition();
    }
  }

  Future<void> _recalculateRouteFromCurrentPosition() async {
    if (_endPoint == null) return;
    
    setState(() {
      _loadingMessage = "Recalculating route...";
    });

    final s = "${_currentPosition.latitude},${_currentPosition.longitude}";
    final e = "${_endPoint!.latitude},${_endPoint!.longitude}";
    final uri = Uri.parse(
      "$_baseUrl/route?start=$s&end=$e&k=$_defaultK&traffic=${_trafficEnabled ? 1 : 0}",
    );

    try {
      final resp = await http.get(uri);
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final encoded = data["polyline"] as String?;
        final dist = (data["total_distance_km"] as num).toDouble();
        
        if (encoded != null) {
          final pts = await compute(_decodePolyline, encoded);
          setState(() {
            _routePoints = pts;
            const id = PolylineId("route");
            _polylines[id] = Polyline(
              polylineId: id,
              color: Colors.blueAccent,
              width: 5,
              points: pts,
            );
            _totalDistance = dist;
            _remainingDistance = dist;
            _loadingMessage = null;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Route recalculated from your current position")),
          );
        }
      }
    } catch (e) {
      debugPrint("Error recalculating route: $e");
    } finally {
      setState(() {
        _loadingMessage = null;
      });
    }
  }

  double _calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final lat1Rad = lat1 * pi / 180;
    final lon1Rad = lon1 * pi / 180;
    final lat2Rad = lat2 * pi / 180;
    final lon2Rad = lon2 * pi / 180;

    final y = sin(lon2Rad - lon1Rad) * cos(lat2Rad);
    final x = cos(lat1Rad) * sin(lat2Rad) - 
              sin(lat1Rad) * cos(lat2Rad) * cos(lon2Rad - lon1Rad);
    final bearing = atan2(y, x);
    return (bearing * 180 / pi + 360) % 360;
  }

  void _updateCameraForNavigation() {
    if (_mapController == null) return;
    
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _currentPosition,
          zoom: 18,
          bearing: _heading,
          tilt: 60,
        ),
      ),
    );
  }

  void _updateETA() {
    if (_endPoint == null || _currentSpeed < 1) return;
    
    final hours = _remainingDistance / _currentSpeed;
    setState(() {
      _estimatedArrivalTime = DateTime.now().add(Duration(hours: hours.toInt()));
    });
  }

  double _calculateDistance(LatLng p1, LatLng p2) {
    final latDiff = p1.latitude - p2.latitude;
    final lngDiff = p1.longitude - p2.longitude;
    return sqrt(latDiff * latDiff + lngDiff * lngDiff) * 111.32;
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

  Future<void> _useCurrentLocation(bool isStart) async {
    try {
      final loc = await _locationService.getLocation();
      if (loc.latitude != null && loc.longitude != null) {
        final currentLoc = LatLng(loc.latitude!, loc.longitude!);
        final address = await _reverseGeocode(currentLoc);
        
        setState(() {
          if (isStart) {
            _startController.text = address;
            _startPoint = currentLoc;
          } else {
            _endController.text = address;
            _endPoint = currentLoc;
          }
          
          final id = isStart ? 'start' : 'end';
          final markerId = MarkerId(id);
          _markers.removeWhere((m) => m.markerId == markerId);
          _markers.add(Marker(
            markerId: markerId,
            position: currentLoc,
            infoWindow: InfoWindow(title: isStart ? 'Start (Current)' : 'End (Current)'),
          ));
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not get current location')),
      );
    }
  }

  Future<String> _reverseGeocode(LatLng position) async {
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      {
        'latlng': '${position.latitude},${position.longitude}',
        'key': _apiKey,
      },
    );
    final resp = await http.get(uri);
    if (resp.statusCode != 200) return 'Current Location';
    final data = json.decode(resp.body);
    if (data['status'] != 'OK' || data['results'].isEmpty) return 'Current Location';
    return data['results'][0]['formatted_address'] ?? 'Current Location';
  }

  Future<List<dynamic>> _fetchSuggestions(String input, {String? sessionToken}) async {
    if (input.isEmpty) return [];
    
    try {
      final params = {
        'input': input,
        'key': _apiKey,
        'components': 'country:ph',
        'sessiontoken': sessionToken ?? _randomSessionToken(),
      };
      
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', params);
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      
      if (resp.statusCode != 200) return [];
      
      final data = json.decode(resp.body);
      
      if (data['status'] != 'OK') return [];
      
      if (data['predictions'] == null) return [];
      
      return data['predictions'];
    } catch (e) {
      return [];
    }
  }

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
      setState(() {
        _loadingMessage = "Fetching shortest route...";
      });

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
          setState(() {
            _loadingMessage = "Rendering route on map...";
          });
          final pts = await compute(_decodePolyline, encoded);
          setState(() {
            _routePoints = pts;
            _currentStep = 0;
          });
          const id = PolylineId("route");
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
            _remainingDistance = dist;
            _loadingMessage = null;
            _hasDirections = true;
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

  Future<void> _getDirections() async {
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

  Future<void> _startTrip() async {
    if (_startController.text.isEmpty || _endController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both start and end locations.')),
      );
      return;
    }
    
    if (!_hasDirections) {
      await _getDirections();
    }
    
    setState(() {
      _isNavigating = true;
      _remainingDistance = _totalDistance;
    });
    
    _updateCameraForNavigation();
    _updateETA();
    _startNavigationUpdates();
  }

  void _cancelTrip() {
    setState(() {
      _isNavigating = false;
    });
    _navigationUpdateTimer?.cancel();
    
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _currentPosition,
          zoom: 16,
          bearing: 0,
          tilt: 0,
        ),
      ),
    );
  }

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
                    if (isStart) {
                      _startDebounceTimer?.cancel();
                    } else {
                      _endDebounceTimer?.cancel();
                    }

                    final timer = Timer(const Duration(milliseconds: 250), () async {
                      if (value.isNotEmpty) {
                        final newSuggestions = await _fetchSuggestions(
                          value,
                          sessionToken: isStart ? _startSessionToken : _endSessionToken,
                        );
                        if (mounted) {
                          setState(() {
                            if (isStart) {
                              _startSuggestions = newSuggestions;
                              _startSessionToken ??= _randomSessionToken();
                            } else {
                              _endSuggestions = newSuggestions;
                              _endSessionToken ??= _randomSessionToken();
                            }
                          });
                        }
                      } else {
                        if (mounted) {
                          setState(() {
                            if (isStart) {
                              _startSuggestions = [];
                            } else {
                              _endSuggestions = [];
                            }
                          });
                        }
                      }
                    });

                    if (isStart) {
                      _startDebounceTimer = timer;
                    } else {
                      _endDebounceTimer = timer;
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
                IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey),
                  onPressed: () {
                    controller.clear();
                    onClearSuggestions();
                    if (isStart) {
                      _startDebounceTimer?.cancel();
                      setState(() => _startSuggestions = []);
                    } else {
                      _endDebounceTimer?.cancel();
                      setState(() => _endSuggestions = []);
                    }
                  },
                ),
              IconButton(
                icon: const Icon(Icons.my_location, size: 20),
                onPressed: () => _useCurrentLocation(isStart),
                tooltip: 'Use current location',
              ),
            ],
          ),
        ),
        if (suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            constraints: const BoxConstraints(maxHeight: 200),
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
                final description = suggestion['description'] ?? '';
                final structured = suggestion['structured_formatting'] ?? {};
                final mainText = structured['main_text'] ?? description;
                final secondaryText = structured['secondary_text'] ?? '';
                
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.location_on, size: 20),
                  title: Text(
                    mainText,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: secondaryText.isNotEmpty
                      ? Text(
                          secondaryText,
                          style: const TextStyle(fontSize: 12),
                        )
                      : null,
                  onTap: () {
                    SystemChannels.textInput.invokeMethod('TextInput.hide');
                    onSuggestionTap(description);
                    onClearSuggestions();
                    setState(() {
                      if (isStart) {
                        _startSuggestions = [];
                      } else {
                        _endSuggestions = [];
                      }
                    });
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Navigation App")),
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
            SwitchListTile(
              title: const Text("Enable Trip"),
              value: _showStartTripButton,
              onChanged: (v) => setState(() => _showStartTripButton = v),
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
            markers: {
              if (_userLocationMarker != null) _userLocationMarker!,
              ..._markers,
            },
            polylines: _polylines.values.toSet(),
            onMapCreated: (c) {
              _mapController = c;
              _mapController!.moveCamera(CameraUpdate.newLatLng(_currentPosition));
            },
            compassEnabled: true,
            rotateGesturesEnabled: !_isNavigating,
            tiltGesturesEnabled: !_isNavigating,
          ),
          
          if (!_isNavigating) Positioned(
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
                  onChanged: (value) {},
                  onClearSuggestions: () {
                    setState(() {
                      _startSuggestions = [];
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
                  onChanged: (value) {},
                  onClearSuggestions: () {
                    setState(() {
                      _endSuggestions = [];
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
            left: 16,
            bottom: 160,
            child: Column(
              children: [
                if (!_isNavigating) FloatingActionButton(
                  backgroundColor: Colors.red,
                  onPressed: _clearEverything,
                  child: const Icon(Icons.clear),
                ),
                const SizedBox(height: 16),
                FloatingActionButton(
                  backgroundColor: Colors.orange,
                  onPressed: _drawRoute,
                  child: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          
          Positioned(
            right: 16,
            bottom: 160,
            child: FloatingActionButton(
              onPressed: _goToCurrentLocation,
              child: const Icon(Icons.my_location),
            ),
          ),
          
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_hasDirections && !_isNavigating) ElevatedButton.icon(
                    onPressed: _getDirections,
                    icon: const Icon(Icons.directions),
                    label: const Text("Get Directions"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: const TextStyle(fontSize: 16),
                    ),
                  ),
                  if (_hasDirections && !_isNavigating && _showStartTripButton) ElevatedButton.icon(
                    onPressed: _startTrip,
                    icon: const Icon(Icons.navigation),
                    label: const Text("Start Trip"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: const TextStyle(fontSize: 16),
                      backgroundColor: Colors.green,
                    ),
                  ),
                  if (_isNavigating) ElevatedButton.icon(
                    onPressed: _cancelTrip,
                    icon: const Icon(Icons.cancel),
                    label: const Text("Cancel Trip"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: const TextStyle(fontSize: 16),
                      backgroundColor: Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          Positioned(
            bottom: 90, 
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "Distance: ${_remainingDistance.toStringAsFixed(2)} km",
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          
          if (_isNavigating) Positioned(
            top: 80,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Text(
                      "Navigating to ${_endController.text}",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Distance remaining: ${_remainingDistance.toStringAsFixed(1)} km",
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Speed: ${_currentSpeed.toStringAsFixed(0)} km/h",
                    ),
                    if (_estimatedArrivalTime != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        "ETA: ${DateFormat('HH:mm').format(_estimatedArrivalTime!)}",
                      ),
                    ],
                  ],
                ),
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