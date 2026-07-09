# In this file, a plan will be uploaded every 2 weeks that will assess the tasks that shall be completed by the end of the upcoming period. For simplicity, a period is always 2 weeks unless specified otherwise.

## Developer A (Backend Lead) (Days 1 - 14)
*Build the serverless infrastructure, notification engine, and RSVP database logic in Supabase/PostgreSQL.*

* **Days 1-3 | Device Registration Architecture:**
  * Create the `user_devices` table to store `user_id`, `push_token` (FCM/APNs), and last known `location` (PostGIS point).
  * Secure the table with strict Row Level Security (RLS) policies so users can only manage their own tokens.
* **Days 4-7 | The RSVP API:**
  * Build the "Join/Request" pipeline using RPCs or standard table inserts.
  * Manage request statuses (`Pending`, `Accepted`, `Rejected`) based on party privacy settings.
* **Days 8-12 | The Edge Function Engine:**
  * Write a Supabase Edge Function (TypeScript) to act as an automated cron job.
  * Query `user_devices` against the `parties` table using PostGIS to detect physical proximity to active events.
* **Days 13-14 | Push Notification Integration:**
  * Connect the Edge Function to Firebase Cloud Messaging (FCM) or Apple Push Notification service (APNs) to deliver proximity payloads to mobile devices.

---

## Developer B (Frontend/Flutter) (Days 1 - 14)
*Connect the interactive map to the database and implement native device features.*

* **Days 1-4 | The Map Controller:**
  * Integrate the map library (e.g., Google Maps, Mapbox) into the Flutter application.
  * Write the camera listener to detect when panning or zooming stops.
* **Days 5-8 | The API Hookup:**
  * Capture the dead-center GPS coordinates and visible radius from the viewport.
  * Pass the payload to the `get_parties_near_user` RPC.
  * Parse the returning JSON and render the Designer's custom pins on the map.
* **Days 9-11 | OS Permissions & Background Tasks:**
  * Implement native iOS/Android code to request background location and notification access.
  * Extract the device Push Token and send it to the backend `user_devices` table.
* **Days 12-14 | UI Polish & Interaction:**
  * Build the sliding bottom sheets based on the Designer's mockups.
  * Wire up the RSVP/Join button to the backend API pipeline.

---

## Handoffs & Dependencies
* **Design -> Frontend:** Developer B is blocked on UI Polish (Days 12-14) until the Designer completes the Modal and Pin designs (Days 1-5).
* **Frontend -> Backend:** Developer A is blocked on testing Push Notifications (Days 13-14) until Developer B successfully registers a real device token in the database (Days 9-11). 
* **Action Item:** Daily cross-team communication is required to ensure API payloads match UI expectations.

---

## UI/UX Designer (Days 1 - 7)
*The visual language and user experience must be defined before the frontend client can be built.*

* **Days 1-3 | The Map Interface:**
  * Design custom map pins differentiating standard house parties, large events, and sponsored mega-festivals.
  * Design the visual logic for "Clustering" (e.g., when multiple parties overlap in a localized area).
* **Days 4-5 | Viewport Modals:**
  * Design the bottom-sheet UI that triggers when a user taps a map pin.
  * Must clearly display: `title`, `description`, `start_time`, and the host's `credibility_score`.
* **Days 6-7 | Permissions & Empty States:**
  * Design native onboarding screens for Background Location and Push Notification permission requests.
  * Design the "Empty State" UI for when the map RPC returns zero nearby parties.
