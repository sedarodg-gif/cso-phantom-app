import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ads_config.dart';

/// Gestion des annonces AdMob : initialisation, interstitielle, bannière.
class Ads {
  static final Completer<bool> _done = Completer<bool>();
  static bool _ok = false;
  static InterstitialAd? _inter;
  static int _count = 0;
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// Complète avec true quand AdMob est prêt (false si désactivé ou en échec).
  static Future<bool> get whenReady => _done.future;

  static Future<void> init() async {
    if (_done.isCompleted) return;
    if (!kAdsEnabled) {
      _done.complete(false);
      return;
    }
    try {
      await MobileAds.instance.initialize();
      _ok = true;
      _loadInterstitial();
    } catch (_) {
      _ok = false;
    }
    if (!_done.isCompleted) _done.complete(_ok);
  }

  static void _loadInterstitial() {
    if (!_ok) return;
    InterstitialAd.load(
      adUnitId: kInterstitialUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (InterstitialAd ad) {
          _inter = ad;
        },
        onAdFailedToLoad: (LoadAdError err) {
          _inter = null;
        },
      ),
    );
  }

  /// À appeler après une déconnexion voulue : affiche une annonce de temps en temps.
  static void maybeShowInterstitial() {
    if (!_ok) return;
    _count++;
    if (_count % kInterstitialEvery != 0) return;
    if (DateTime.now().difference(_last).inMinutes < kInterstitialMinGapMin) return;
    final ad = _inter;
    if (ad == null) {
      _loadInterstitial();
      return;
    }
    _inter = null;
    ad.fullScreenContentCallback = FullScreenContentCallback<InterstitialAd>(
      onAdDismissedFullScreenContent: (InterstitialAd a) {
        a.dispose();
        _loadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (InterstitialAd a, AdError e) {
        a.dispose();
        _loadInterstitial();
      },
    );
    ad.show();
    _last = DateTime.now();
  }
}

/// Bannière : n'occupe aucune place tant qu'aucune annonce n'est chargée.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    Ads.whenReady.then((bool ok) {
      if (!ok || !mounted) return;
      final b = BannerAd(
        adUnitId: kBannerUnitId,
        size: AdSize.banner,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (Ad ad) {
            if (mounted) setState(() => _loaded = true);
          },
          onAdFailedToLoad: (Ad ad, LoadAdError err) {
            ad.dispose();
            if (mounted) {
              setState(() {
                _ad = null;
                _loaded = false;
              });
            }
          },
        ),
      );
      _ad = b;
      b.load();
    });
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Center(
        child: SizedBox(
          width: ad.size.width.toDouble(),
          height: ad.size.height.toDouble(),
          child: AdWidget(ad: ad),
        ),
      ),
    );
  }
}
