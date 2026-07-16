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

 Future<void> _fetchEventsInBounds() async {
    final center = _mapController.camera.center;
    final bounds = _mapController.camera.visibleBounds;

    final Distance distance = const Distance();
    
    // Πολλαπλασιάζουμε επί 2.0 για να νικήσουμε την καμπυλότητα της Γης στο extreme zoom!
    final double radiusInMeters = distance.as(
      LengthUnit.Meter,
      center,
      bounds.northEast,
    ) * 2.0;

    try {
      // Καλούμε το ΠΡΑΓΜΑΤΙΚΟ όνομα της συνάρτησης του Developer A
      final response = await Supabase.instance.client.rpc(
        'get_parties_near_user', 
        params: {
          // ΠΡΟΣΟΧΗ: Ο Dev A έβαλε πρώτα το LON στο SQL του!
          'map_center_lon': center.longitude,
          'map_center_lat': center.latitude,
          'radius_meters': radiusInMeters,
        },
      );
      
      List<Marker> markers = [];
      for (var event in response) {
        if (event['lat'] != null && event['lon'] != null) {
          markers.add(
            Marker(
              point: LatLng(event['lat'], event['lon']),
              width: 60,
              height: 60,
              child: const Icon(
                Icons.location_on,
                color: Colors.deepPurple,
                size: 40,
              ),
            ),
          );
        }
      }
      
      if (mounted) {
        setState(() {
          _eventMarkers = markers;
        });
      }
    } catch (e) {
      debugPrint('Error loading parties: $e');
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