import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async'; 

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  Timer? _debounce;
  LatLng? _currentPosition;
  List<Marker> _eventMarkers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    await _getUserLocation();
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  // 1. Ζητάμε άδεια και βρίσκουμε το GPS του χρήστη
  Future<void> _getUserLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    if (permission == LocationPermission.deniedForever) return;

    Position position = await Geolocator.getCurrentPosition();
    _currentPosition = LatLng(position.latitude, position.longitude);
  }

  // 2. Τραβάμε τα "dummy" πάρτι από τη βάση του Developer A
  Future<void> _fetchEventsInBounds() async {
    // 1. Παίρνουμε τα όρια της οθόνης από τον controller του χάρτη
    final bounds = _mapController.camera.visibleBounds;
    
    final minLat = bounds.southWest.latitude;
    final maxLat = bounds.northEast.latitude;
    final minLng = bounds.southWest.longitude;
    final maxLng = bounds.northEast.longitude;

    try {
      // 2. Καλούμε το νέο RPC του Developer A (έστω ότι το ονόμασε get_parties_in_bounds)
      final response = await Supabase.instance.client.rpc(
        'get_parties_in_bounds', // <-- Ζήτα από τον Dev A το ακριβές όνομα!
        params: {
          'min_lat': minLat,
          'max_lat': maxLat,
          'min_lng': minLng,
          'max_lng': maxLng,
        },
      );
      
      // 3. Μετατρέπουμε τα αποτελέσματα σε πινέζες
      List<Marker> markers = [];
      for (var event in response) {
        if (event['latitude'] != null && event['longitude'] != null) {
          markers.add(
            Marker(
              point: LatLng(event['latitude'], event['longitude']),
              width: 80,
              height: 80,
              child: const Icon(
                Icons.location_on,
                color: Colors.deepPurple,
                size: 40,
              ),
            ),
          );
        }
      }
      
      // 4. Ανανεώνουμε την οθόνη
      if (mounted) {
        setState(() {
          _eventMarkers = markers;
        });
      }
    } catch (e) {
      debugPrint('Σφάλμα κατά τη φόρτωση των parties: $e');
    }
  }

  @override
    Widget build(BuildContext context) {
      if (_isLoading) {
        return const Center(child: CircularProgressIndicator(color: Colors.deepPurple));
      }

      // Αν δεν βρήκαμε τοποθεσία, βάζουμε μια προεπιλεγμένη (π.χ. κέντρο Αθήνας)
      final startingPoint = _currentPosition ?? const LatLng(37.9838, 23.7275);

      return FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: startingPoint,
          initialZoom: 13.0,
          
          // 1. ΠΡΟΣΘΗΚΗ: Μόλις ο χάρτης είναι έτοιμος, τραβάει τα parties
          onMapReady: () {
            _fetchEventsInBounds();
          },

          // Αυτό το κομμάτι "ακούει" την κίνηση του χάρτη!
          onPositionChanged: (position, hasGesture) {
            // Αν τρέχει ήδη χρονόμετρο, ακύρωσέ το (γιατί ο χρήστης συνεχίζει να κουνάει)
            if (_debounce?.isActive ?? false) _debounce!.cancel();
            
            // Ξεκίνα ένα νέο χρονόμετρο 500 χιλιοστών του δευτερολέπτου
            _debounce = Timer(const Duration(milliseconds: 500), () {
              _fetchEventsInBounds(); // Όταν σταματήσει, καλεί τη βάση
            });
          },
        ),
        children: [
          // Το υπόβαθρο του χάρτη (OpenStreetMap)
          TileLayer(
            // Pointing to CartoDB's Dark Matter servers
            urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
            subdomains: const ['a', 'b', 'c', 'd'],
            userAgentPackageName: 'com.myparty.app',
          ),
          // Το Layer με τις πινέζες των πάρτι
          MarkerLayer(
            markers: _eventMarkers,
          ),
          // Το Layer με την πινέζα του χρήστη (Μπλε κουκκίδα)
          if (_currentPosition != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: _currentPosition!,
                  child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
                )
              ],
            ),
        ],
      );
    }
}