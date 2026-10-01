MyParty – App Overview & Technical Documentation
Welcome to MyParty, a next-generation nightlife and social discovery application designed to connect users with real-world parties, house events, and club nights through an interactive, map-first interface.

1. App Overview & Concept
MyParty shifts away from traditional static event feeds by centering the user experience around a dynamic, real-time map. The app is built on a premium Dark Neon aesthetic (glassy dark backgrounds with vibrant neon-purple accents) tailored for nightlife exploration.

Core Features
Map-First Discovery (flutter_map): The central tab features an interactive map utilizing CartoDB Dark Matter tiles. Users can pan across cities (e.g., from Athens to Patra) to discover local events.

Geospatial Zoom-Tier Decluttering: Leveraging advanced PostGIS spatial logic, the backend automatically filters events based on the user's viewport radius:

Zoomed In (≤ 15km): Shows all parties (including small house parties).

Medium Zoom (≤ 100km): Displays regional large events.

Zoomed Out (Globe view): Filters down to mega-events and sponsored parties only.

Party Details & Social Interaction: Tapping on a party card reveals full event information (host credentials, start time, tier, and descriptions) rather than jumping straight into a chat.

RSVP & Counters: Interactive "Interested" and "Going" buttons that dynamically update local and database-backed event counters.

User Profile & Stats: Displays user identity, custom avatars, credibility scores, and live counters tracking "Parties Attended" and "Parties Hosted."

2. Technical Architecture & Tech Stack
The application relies on a modern, decoupled client-server architecture designed for high scalability and real-time spatial queries.

Frontend
Framework: Flutter (Cross-platform iOS/Android development).

State Management & UI: Modular component-based structure ("Lego" architecture), custom dark theme implementations, and responsive layouts.

Mapping Library: flutter_map combined with latlong2 for local geometry and bounding-box/radius distance calculations.

Assets: Custom vector icons and localized placeholders ready for future graphic design assets.

Backend & Database
BaaS (Backend as a Service): Supabase.

Database & Spatial Extension: PostgreSQL empowered by PostGIS for high-performance geospatial operations (st_dwithin, st_distance, geographic points).

Custom RPC Functions: Optimized stored procedures (e.g., get_parties_near_user) handling complex viewport logic and tier-based filtering on the database level.

Development & Version Control
Workflow: Feature-branch git workflow (development, feature/explore-ui, feature/custom-map-pins).

Containerization: Docker for local Supabase and database environment management.

Code Editor: Cursor & Visual Studio Code.
