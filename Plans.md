# In this file, a plan will be uploaded every 2 weeks that will assess the tasks that shall be completed by the end of the upcoming period. For simplicity, a period is always 2 weeks unless specified otherwise.

## Developer A: Infrastructure & Database
*Focus: Ensuring data is structured, secure, and geographically queryable.*

* **Day 1 - Version Control Setup:** Create the GitHub repository, configure the `development` branch, and set up strict branch protection rules. Invite your colleague and establish the baseline `.gitignore` to prevent sensitive API keys from leaking and triggering access restrictions.
* **Days 2 to 5 - Database & PostGIS Provisioning:** Initialize the Supabase project. Design and execute the normalized SQL schema for the `Users` and `Parties` tables. Enable the PostGIS extension and write the initial SQL queries to insert dummy party coordinates.
* **Days 6 to 8 - Backend Authentication:** Configure Supabase Auth settings (like email/password providers) and set up Row Level Security (RLS) policies in PostgreSQL so users can only modify their own parties.
* **Days 9 to 14 - API / RPC Setup:** Write the Supabase Remote Procedure Calls (RPCs) that the frontend will trigger to execute the complex spatial queries (e.g., fetching parties within a specific radius).
no other 
---

## Developer B: Client & Integration
*Focus: Ensuring the app renders fluidly, handles user input, and successfully requests data.*

* **Day 1 - Environment Verification:** Clone the shared repository. Verify the local environment runs the base Flutter SDK and the iOS/Android emulators without path errors.
* **Days 2 to 5 - Flutter Skeleton Initialization:** Create the base Flutter project architecture (separating UI, models, and network services). Import the `supabase_flutter` package and configure the environment variables securely in `main.dart`.
* **Days 6 to 10 - Frontend Authentication:** Build the raw, unpolished UI for Login and Registration screens. Wire the UI text fields and buttons to the Supabase Auth SDK and confirm test users successfully populate in Developer A's database dashboard.
* **Days 11 to 14 - Map Interface Rendering:** Import the mapping package (e.g., `flutter_map`). Build the core map screen, request device location permissions, and fetch the dummy coordinate payload from Developer A's database to successfully drop a pin on the screen.

---

## The Critical Sync Points
You cannot work entirely in silos. Both developers must coordinate specifically on these days:

* **Day 1:** Agree on branch naming conventions (e.g., `feature/auth-ui`) and mandatory Pull Request reviews to keep the main codebase stable.
* **Day 6:** Coordinate the Auth variables. Developer B cannot test the login UI if Developer A has not enabled the correct authentication providers in Supabase.
* **Day 11:** Match the data models. Developer B's Dart classes must perfectly mirror the JSON payload structure that Developer A's database queries return, otherwise the map will fail to render the pins.