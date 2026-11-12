// ======================================================================
//  CONFIGURATION DES ANNONCES (Google AdMob)
//
//  Les identifiants ci-dessous sont les identifiants de TEST officiels de
//  Google : ils affichent de fausses annonces et ne rapportent RIEN.
//  Pour gagner de l'argent, remplace-les par les tiens (compte AdMob) :
//    1. kAdmobAppId        -> « ID de l'application » (forme ca-app-pub-xxx~yyy)
//    2. kBannerUnitId      -> bloc d'annonces « Bannière »  (forme ca-app-pub-xxx/zzz)
//    3. kInterstitialUnitId-> bloc d'annonces « Interstitielle »
//  Ne clique JAMAIS toi-même sur tes annonces : AdMob suspend les comptes.
// ======================================================================

/// Mets false pour désactiver complètement les annonces.
const bool kAdsEnabled = true;

const String kAdmobAppId = 'ca-app-pub-3940256099942544~3347511713';
const String kBannerUnitId = 'ca-app-pub-3940256099942544/6300978111';
const String kInterstitialUnitId = 'ca-app-pub-3940256099942544/1033173712';

/// Une annonce plein écran toutes les N déconnexions...
const int kInterstitialEvery = 3;

/// ...et jamais plus d'une toutes les X minutes.
const int kInterstitialMinGapMin = 5;
