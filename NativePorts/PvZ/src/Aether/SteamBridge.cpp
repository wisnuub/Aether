/*
 * Copyright (C) 2026 Aether contributors
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Aether SteamBridge. See SteamBridge.h.
 *
 * Uses Steam's flat C API, resolved with dlopen/dlsym from libsteam_api.dylib
 * next to the executable. Interface versions match Steamworks SDK 1.62.
 */

#ifdef AETHER_STEAM

#include "SteamBridge.h"
#include "../PvzpLib/PvzpDebug.h"

#include <cstdint>
#include <cstring>
#include <ctime>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <system_error>
#include <vector>

#include <sys/stat.h>
#include <sys/time.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

namespace fs = std::filesystem;

namespace
{
	constexpr uint32_t kAppId = 3590;

	// ---- Steam flat API (only what is used) --------------------------------
	using Fn_InitFlat = int (*)(char* theErrMsg1024);   // 0 == OK
	using Fn_Void = void (*)();
	using Fn_Restart = bool (*)(uint32_t);
	using Fn_Accessor = void* (*)();
	using Fn_FileWrite = bool (*)(void*, const char*, const void*, int32_t);
	using Fn_FileRead = int32_t (*)(void*, const char*, void*, int32_t);
	using Fn_NameBool = bool (*)(void*, const char*);
	using Fn_Timestamp = int64_t (*)(void*, const char*);
	using Fn_Count = int32_t (*)(void*);
	using Fn_NameSize = const char* (*)(void*, int, int32_t*);
	using Fn_SelfBool = bool (*)(void*);
	using Fn_GetAch = bool (*)(void*, const char*, bool*);
	using Fn_GetAppId = uint32_t (*)(void*);
	using Fn_GetSteamId = uint64_t (*)(void*);

	struct SteamApi
	{
		void* mLib = nullptr;
		Fn_InitFlat InitFlat = nullptr;
		Fn_Void Shutdown = nullptr;
		Fn_Void RunCallbacks = nullptr;
		Fn_Restart RestartAppIfNecessary = nullptr;
		Fn_Accessor RemoteStorage = nullptr;
		Fn_Accessor UserStats = nullptr;
		Fn_Accessor Utils = nullptr;
		Fn_Accessor User = nullptr;
		Fn_FileWrite FileWrite = nullptr;
		Fn_FileRead FileRead = nullptr;
		Fn_NameBool FileExists = nullptr;
		Fn_NameBool FileDelete = nullptr;
		Fn_Timestamp GetFileTimestamp = nullptr;
		Fn_Count GetFileCount = nullptr;
		Fn_NameSize GetFileNameAndSize = nullptr;
		Fn_SelfBool CloudEnabledForAccount = nullptr;
		Fn_SelfBool CloudEnabledForApp = nullptr;
		Fn_GetAch GetAchievement = nullptr;
		Fn_NameBool SetAchievement = nullptr;
		Fn_SelfBool StoreStats = nullptr;
		Fn_GetAppId GetAppID = nullptr;
		Fn_GetSteamId GetSteamID = nullptr;
	};

	SteamApi gApi;
	bool gLoaded = false;
	bool gActive = false;

	std::string ExecutableDir()
	{
#ifdef __APPLE__
		uint32_t aSize = 0;
		_NSGetExecutablePath(nullptr, &aSize);
		std::string aPath(aSize, '\0');
		if (_NSGetExecutablePath(aPath.data(), &aSize) != 0)
			return ".";
		aPath.resize(strlen(aPath.c_str()));
		return fs::path(aPath).parent_path().string();
#else
		std::error_code ec;
		return fs::read_symlink("/proc/self/exe", ec).parent_path().string();
#endif
	}

	template <typename T>
	bool Bind(T& theFn, const char* theName)
	{
		theFn = reinterpret_cast<T>(dlsym(gApi.mLib, theName));
		if (!theFn)
			PvzpLogLn("SteamBridge: missing symbol {}", theName);
		return theFn != nullptr;
	}

	bool LoadSteamApi()
	{
		if (gLoaded)
			return gApi.mLib != nullptr;
		gLoaded = true;

#ifdef __APPLE__
		const char* aLibName = "libsteam_api.dylib";
#else
		const char* aLibName = "libsteam_api.so";
#endif
		const std::string aPath = (fs::path(ExecutableDir()) / aLibName).string();
		gApi.mLib = dlopen(aPath.c_str(), RTLD_NOW | RTLD_LOCAL);
		if (!gApi.mLib)
		{
			PvzpLogLn("SteamBridge: {} not loaded ({})", aPath, dlerror());
			return false;
		}

		bool aOk = true;
		aOk &= Bind(gApi.InitFlat, "SteamAPI_InitFlat");
		aOk &= Bind(gApi.Shutdown, "SteamAPI_Shutdown");
		aOk &= Bind(gApi.RunCallbacks, "SteamAPI_RunCallbacks");
		aOk &= Bind(gApi.RestartAppIfNecessary, "SteamAPI_RestartAppIfNecessary");
		aOk &= Bind(gApi.RemoteStorage, "SteamAPI_SteamRemoteStorage_v016");
		aOk &= Bind(gApi.UserStats, "SteamAPI_SteamUserStats_v013");
		aOk &= Bind(gApi.Utils, "SteamAPI_SteamUtils_v010");
		aOk &= Bind(gApi.User, "SteamAPI_SteamUser_v023");
		aOk &= Bind(gApi.FileWrite, "SteamAPI_ISteamRemoteStorage_FileWrite");
		aOk &= Bind(gApi.FileRead, "SteamAPI_ISteamRemoteStorage_FileRead");
		aOk &= Bind(gApi.FileExists, "SteamAPI_ISteamRemoteStorage_FileExists");
		aOk &= Bind(gApi.FileDelete, "SteamAPI_ISteamRemoteStorage_FileDelete");
		aOk &= Bind(gApi.GetFileTimestamp, "SteamAPI_ISteamRemoteStorage_GetFileTimestamp");
		aOk &= Bind(gApi.GetFileCount, "SteamAPI_ISteamRemoteStorage_GetFileCount");
		aOk &= Bind(gApi.GetFileNameAndSize, "SteamAPI_ISteamRemoteStorage_GetFileNameAndSize");
		aOk &= Bind(gApi.CloudEnabledForAccount, "SteamAPI_ISteamRemoteStorage_IsCloudEnabledForAccount");
		aOk &= Bind(gApi.CloudEnabledForApp, "SteamAPI_ISteamRemoteStorage_IsCloudEnabledForApp");
		aOk &= Bind(gApi.GetAchievement, "SteamAPI_ISteamUserStats_GetAchievement");
		aOk &= Bind(gApi.SetAchievement, "SteamAPI_ISteamUserStats_SetAchievement");
		aOk &= Bind(gApi.StoreStats, "SteamAPI_ISteamUserStats_StoreStats");
		aOk &= Bind(gApi.GetAppID, "SteamAPI_ISteamUtils_GetAppID");
		aOk &= Bind(gApi.GetSteamID, "SteamAPI_ISteamUser_GetSteamID");
		if (!aOk)
		{
			dlclose(gApi.mLib);
			gApi = SteamApi();
			return false;
		}
		return true;
	}

	// Steam API names, in AchievementId order (see AchievementsScreen.h).
	const char* const kAchievementApiNames[] = {
		"finished_adventure",    // HomeSecurity
		"gold_sunflower_trophy", // NovelPeasPrize
		"izombie_streak",        // BetterOffDead
		"vasebreaker_streak",    // ChinaShop
		"potato_mine",           // Spudow
		"cherry_bomb",           // Explodonator
		"all_plants",            // Morticulturalist
		"pea_pool",              // DontPea
		"roll_heads",            // RollSomeHeads
		"grounded",              // Grounded
		"secret_zombie",         // Zombologist
		"penny_pincher",         // PennyPincher
		"sunny_days",            // SunnyDays
		"popcorn",               // PopcornParty
		"good_morning",          // GoodMorning
		"no_fungus",             // NoFungusAmongUs
		"minigames",             // BeyondTheGrave
		"survival_streak",       // Immortal
		"tall_tree",             // ToweringWisdom
		"mustache_mode",         // MustacheMode
	};
	constexpr int kNumMapped = static_cast<int>(sizeof(kAchievementApiNames) / sizeof(kAchievementApiNames[0]));

	// Only the profile files are shared with the Windows build. Its mid-level
	// saves are raw 32-bit memory dumps; this runtime writes portable .v4 files.
	bool IsSyncedSaveName(const std::string& theName)
	{
		static const std::regex aPattern(R"(^(users\.dat|user[0-9]+\.dat)$)");
		return std::regex_match(theName, aPattern);
	}

	void* Storage() { return gApi.RemoteStorage(); }
	void* Stats() { return gApi.UserStats(); }

	bool CloudEnabled()
	{
		void* aStorage = Storage();
		return aStorage && gApi.CloudEnabledForAccount(aStorage) && gApi.CloudEnabledForApp(aStorage);
	}

	bool SetIfLocked(const char* theApiName)
	{
		bool aAchieved = false;
		if (!gApi.GetAchievement(Stats(), theApiName, &aAchieved) || aAchieved)
			return false;
		return gApi.SetAchievement(Stats(), theApiName);
	}

	std::time_t LocalMTime(const fs::path& thePath)
	{
		struct stat aStat;
		return stat(thePath.c_str(), &aStat) == 0 ? aStat.st_mtime : 0;
	}

	void SetLocalMTime(const fs::path& thePath, std::time_t theTime)
	{
		struct timeval aTimes[2] = {{static_cast<time_t>(theTime), 0}, {static_cast<time_t>(theTime), 0}};
		utimes(thePath.c_str(), aTimes);
	}
}

namespace SteamBridge
{
	bool RestartThroughSteamIfNeeded()
	{
		// False when started by Steam, when steam_appid.txt is present
		// (development), or when Steam is not installed.
		return LoadSteamApi() && gApi.RestartAppIfNecessary(kAppId);
	}

	bool Init()
	{
		if (gActive)
			return true;
		if (!LoadSteamApi())
			return false;

		char aErr[1024] = {};
		if (gApi.InitFlat(aErr) != 0)
		{
			PvzpLogLn("SteamBridge: Steam not available ({})", aErr);
			return false;
		}
		gActive = true;
		PvzpLogLn("SteamBridge: connected as app {} for {}", gApi.GetAppID(gApi.Utils()), gApi.GetSteamID(gApi.User()));
		return true;
	}

	void Shutdown()
	{
		if (!gActive)
			return;
		gApi.StoreStats(Stats());
		gApi.Shutdown();
		gActive = false;
	}

	bool IsActive() { return gActive; }

	void RunCallbacks()
	{
		if (gActive)
			gApi.RunCallbacks();
	}

	void SyncCloudSaves(const std::string& theUserDataDir)
	{
		if (!gActive)
			return;
		if (!CloudEnabled())
		{
			PvzpLogLn("SteamBridge: Steam Cloud is off for this account or game, using local saves");
			return;
		}

		void* aStorage = Storage();
		const fs::path aDir(theUserDataDir);
		std::error_code ec;
		fs::create_directories(aDir, ec);

		// Cloud -> local, for cloud copies newer than the local file.
		const int32_t aCount = gApi.GetFileCount(aStorage);
		for (int32_t i = 0; i < aCount; i++)
		{
			int32_t aSize = 0;
			const char* aNameC = gApi.GetFileNameAndSize(aStorage, i, &aSize);
			if (!aNameC || aSize <= 0)
				continue;
			const std::string aName = aNameC;
			if (!IsSyncedSaveName(aName))
				continue;

			const std::time_t aCloudTime = static_cast<std::time_t>(gApi.GetFileTimestamp(aStorage, aNameC));
			const fs::path aLocal = aDir / aName;
			const bool aHaveLocal = fs::exists(aLocal, ec);
			const std::time_t aLocalTime = aHaveLocal ? LocalMTime(aLocal) : 0;
			if (aHaveLocal && aCloudTime <= aLocalTime)
				continue;

			std::vector<char> aData(static_cast<size_t>(aSize));
			const int32_t aRead = gApi.FileRead(aStorage, aNameC, aData.data(), aSize);
			if (aRead != aSize)
			{
				PvzpLogLn("SteamBridge: reading {} from Steam Cloud failed ({} of {} bytes)", aName, aRead, aSize);
				continue;
			}
			if (aHaveLocal)
			{
				const fs::path aBackupDir = aDir / "cloud-backup";
				fs::create_directories(aBackupDir, ec);
				fs::copy_file(aLocal, aBackupDir / (aName + "." + std::to_string(aLocalTime)),
					fs::copy_options::overwrite_existing, ec);
			}
			std::ofstream aOut(aLocal, std::ios::binary | std::ios::trunc);
			aOut.write(aData.data(), aRead);
			aOut.close();
			SetLocalMTime(aLocal, aCloudTime);
			PvzpLogLn("SteamBridge: downloaded {} ({} bytes)", aName, aRead);
		}

		// Local -> cloud, for local files newer than the cloud copy or missing there
		// (for example progress made while Steam was offline).
		for (const auto& aEntry : fs::directory_iterator(aDir, ec))
		{
			if (!aEntry.is_regular_file(ec))
				continue;
			const std::string aName = aEntry.path().filename().string();
			if (!IsSyncedSaveName(aName))
				continue;
			const bool aInCloud = gApi.FileExists(aStorage, aName.c_str());
			const std::time_t aCloudTime = aInCloud ? static_cast<std::time_t>(gApi.GetFileTimestamp(aStorage, aName.c_str())) : 0;
			if (aInCloud && LocalMTime(aEntry.path()) <= aCloudTime)
				continue;

			std::ifstream aIn(aEntry.path(), std::ios::binary);
			std::vector<char> aData((std::istreambuf_iterator<char>(aIn)), std::istreambuf_iterator<char>());
			if (!aData.empty() && gApi.FileWrite(aStorage, aName.c_str(), aData.data(), static_cast<int32_t>(aData.size())))
				PvzpLogLn("SteamBridge: uploaded newer local {} ({} bytes)", aName, aData.size());
		}
	}

	void PushCloudFile(const std::string& theName, const void* theData, size_t theLen)
	{
		if (!gActive || !IsSyncedSaveName(theName) || !CloudEnabled())
			return;
		if (!gApi.FileWrite(Storage(), theName.c_str(), theData, static_cast<int32_t>(theLen)))
			PvzpLogLn("SteamBridge: writing {} to Steam Cloud failed", theName);
	}

	void DeleteCloudFile(const std::string& theName)
	{
		if (!gActive || !IsSyncedSaveName(theName))
			return;
		if (gApi.FileExists(Storage(), theName.c_str()))
			gApi.FileDelete(Storage(), theName.c_str());
	}

	void UnlockAchievement(int theAchievement)
	{
		if (!gActive || theAchievement < 0 || theAchievement >= kNumMapped)
			return;
		if (SetIfLocked(kAchievementApiNames[theAchievement]))
			gApi.StoreStats(Stats());
	}

	void SyncEarnedAchievements(const bool* theEarned, int theCount)
	{
		if (!gActive || !theEarned)
			return;
		bool aChanged = false;
		for (int i = 0; i < theCount && i < kNumMapped; i++)
			if (theEarned[i] && SetIfLocked(kAchievementApiNames[i]))
				aChanged = true;
		if (aChanged)
			gApi.StoreStats(Stats());
	}

	void UnlockAchievementByApiName(const char* theApiName)
	{
		if (!gActive || !theApiName)
			return;
		if (SetIfLocked(theApiName))
			gApi.StoreStats(Stats());
	}
}

#endif // AETHER_STEAM
