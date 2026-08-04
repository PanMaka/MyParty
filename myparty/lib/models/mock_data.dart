import 'party_model.dart';
import 'story_model.dart';
import 'post_model.dart';

const List<Party> dummyTrendingParties = [
  Party(
    id: 'party_001',
    title: 'Koukaki House Party',
    locationName: 'Koukaki Loft',
    time: 'Sat, 10:30 PM',
    category: 'House Party',
    attendeeCount: 78,
    imageUrl: 'https://images.unsplash.com/photo-1519671482749-fd09be7ccebf?auto=format&fit=crop&w=1000&q=80',
  ),
  Party(
    id: 'party_002',
    title: 'Gazi Warehouse Club',
    locationName: 'Technopolis',
    time: 'Fri, 11:45 PM',
    category: 'Club Night',
    attendeeCount: 210,
    imageUrl: 'https://images.unsplash.com/photo-1500534623283-312aade485b7?auto=format&fit=crop&w=1000&q=80',
  ),
  Party(
    id: 'party_003',
    title: 'Plaka Sunset DJ Set',
    locationName: 'Anafiotika Terrace',
    time: 'Sun, 9:00 PM',
    category: 'Rooftop Party',
    attendeeCount: 142,
    imageUrl: 'https://images.unsplash.com/photo-1497032205916-ac775f0649ae?auto=format&fit=crop&w=1000&q=80',
  ),
  Party(
    id: 'party_004',
    title: 'Kolonaki Neon Lounge',
    locationName: 'Vogue Club',
    time: 'Sat, 12:00 AM',
    category: 'Lounge Night',
    attendeeCount: 95,
    imageUrl: 'https://images.unsplash.com/photo-1517841905240-472988babdf9?auto=format&fit=crop&w=1000&q=80',
  ),
  Party(
    id: 'party_005',
    title: 'Piraeus Shipyard Rave',
    locationName: 'Port Warehouse',
    time: 'Sat, 1:30 AM',
    category: 'Rave',
    attendeeCount: 320,
    imageUrl: 'https://images.unsplash.com/photo-1512453979798-5ea266f8880c?auto=format&fit=crop&w=1000&q=80',
  ),
];

const List<Story> dummyStories = [
  Story(
    id: 'story_you',
    label: 'Your Story',
    imageUrl: 'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?auto=format&fit=crop&w=300&q=80',
  ),
  Story(
    id: 'story_001',
    label: 'Techno Noir',
    imageUrl: 'https://images.unsplash.com/photo-1571266028243-d220c9c3b31c?auto=format&fit=crop&w=400&q=80',
    isLive: true,
    liveViewerCount: 623,
  ),
  Story(
    id: 'story_002',
    label: 'House 24',
    imageUrl: 'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?auto=format&fit=crop&w=400&q=80',
    startsInText: 'Starts in 2h',
  ),
  Story(
    id: 'story_003',
    label: 'Neon Rooftop',
    imageUrl: 'https://images.unsplash.com/photo-1571019613454-1cb2f99b2d8b?auto=format&fit=crop&w=400&q=80',
    startsInText: 'Starts in 5h',
  ),
];

const List<FeedPost> dummyFeedPosts = [
  FeedPost(
    id: 'post_001',
    authorName: 'Techno Noir',
    authorAvatarUrl: 'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?auto=format&fit=crop&w=200&q=80',
    postedAgo: '2h ago',
    locationName: 'Athens',
    caption: 'Doors open. See you inside. 🖤',
    imageUrl: 'https://images.unsplash.com/photo-1571266028243-d220c9c3b31c?auto=format&fit=crop&w=1000&q=80',
    imageBadge: 'Techno Noir · Tonight',
    likeCount: 532,
    commentCount: 82,
  ),
  FeedPost(
    id: 'post_002',
    authorName: 'Sunset Rooftop',
    authorAvatarUrl: 'https://images.unsplash.com/photo-1544005313-94ddf0286df2?auto=format&fit=crop&w=200&q=80',
    postedAgo: '4h ago',
    locationName: 'Athens',
    caption: 'The vibe tonight. 🌆',
    imageUrl: 'https://images.unsplash.com/photo-1533174072545-7a4b6ad7a6c3?auto=format&fit=crop&w=1000&q=80',
    imageBadge: 'Sunset Rooftop · Tonight',
    likeCount: 318,
    commentCount: 47,
  ),
];
