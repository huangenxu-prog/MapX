Organic Maps original-source baseline

Pinned upstream: https://github.com/organicmaps/organicmaps/commit/694861218380a6164c518b81b30ca55b412b6cae

Build uses upstream Xcode workspace and recursive submodules without modifying navigation, UI, map services or attribution. Source is checked out at CI runtime, not vendored in this branch. Original app identifier is retained for initial unsigned build; installation requires signing. No TestFlight credentials. Verify China map coverage, offline download, vehicle and pedestrian navigation, voice, rerouting and background behavior before simplifying or rebranding. Existing MapX main and navigation-refinement remain unchanged.
