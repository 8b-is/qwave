/**
 * bonfire — i18n: four ways to read the fire
 * ============================================================================
 * The UI speaks four languages: Hungarian (the fire's own tongue), English,
 * Chinese, and Rovásírás — Hungarian rendered in the Old Hungarian script
 * (U+10C80 block), read right-to-left. Rovásírás is a script, not a language:
 * it is computed from the Hungarian strings via the phoneme table below, so
 * it can never drift from what the fire actually says.
 *
 * Code stays English (house rule). Only visitor-facing strings live here.
 * Isomorphic: imported by page scripts and served raw at /shared/*. No DOM
 * access, no node imports.
 * ============================================================================
 */

export const LANGS = Object.freeze(['hu', 'en', 'zh', 'rovas']);
export const DEFAULT_LANG = 'hu';
export const RTL_LANGS = new Set(['rovas']);
export const LOCALES = Object.freeze({ hu: 'hu-HU', en: 'en-GB', zh: 'zh-CN', rovas: 'hu-HU' });

/* -- the róvás phoneme table, longest match first --------------------------- */
const ROVAS = [
  ['dzs', '𐲇'], ['cs', '𐲄'], ['sz', '𐲟'], ['zs', '𐲨'], ['ty', '𐲡'],
  ['gy', '𐲌'], ['ly', '𐲔'], ['ny', '𐲗'], ['dz', '𐲆'],
  ['a', '𐲀'], ['á', '𐲁'], ['b', '𐲂'], ['c', '𐲃'], ['d', '𐲅'],
  ['e', '𐲈'], ['é', '𐲉'], ['f', '𐲊'], ['g', '𐲋'], ['h', '𐲍'],
  ['i', '𐲎'], ['í', '𐲏'], ['j', '𐲐'], ['k', '𐲑'], ['l', '𐲓'],
  ['m', '𐲕'], ['n', '𐲖'], ['o', '𐲘'], ['ó', '𐲙'], ['ö', '𐲚'],
  ['ő', '𐲛'], ['p', '𐲜'], ['r', '𐲝'], ['s', '𐲞'], ['t', '𐲠'],
  ['u', '𐲢'], ['ú', '𐲣'], ['ü', '𐲤'], ['ű', '𐲥'], ['v', '𐲦'],
  ['z', '𐲧'], ['q', '𐲑'], ['w', '𐲦'], ['x', '𐲑𐲟'], ['y', '𐲎'],
];

/** Hungarian → Old Hungarian script. Foreign letters, digits and punctuation
 *  pass through — modern róvás usage keeps Arabic numerals. */
export function toRovas(text) {
  const s = String(text).toLowerCase();
  let out = '';
  let i = 0;
  while (i < s.length) {
    let hit = null;
    for (const [latin, rune] of ROVAS) {
      if (s.startsWith(latin, i)) { hit = rune; i += latin.length; break; }
    }
    out += hit ?? s[i++];
  }
  return out;
}

/* -- VAD label words (shared/wave.js vadLabel) ------------------------------ */
const VAD_WORDS = {
  'sötét': { en: 'dark', zh: '暗' },
  'meleg': { en: 'warm', zh: '暖' },
  'semleges': { en: 'neutral', zh: '中性' },
  'csendes': { en: 'quiet', zh: '静' },
  'lángoló': { en: 'blazing', zh: '炽热' },
  'egyenletes': { en: 'steady', zh: '平稳' },
  'kérdező': { en: 'questioning', zh: '探问' },
  'biztos': { en: 'certain', zh: '笃定' },
  'kereső': { en: 'searching', zh: '寻觅' },
};

export function translateVadLabel(label, l) {
  const lang = l ?? current;
  if (lang === 'rovas') return toRovas(label);
  if (lang === 'hu') return label;
  return label.split(' · ').map((w) => VAD_WORDS[w]?.[lang] ?? w).join(' · ');
}

/* -- the dictionary --------------------------------------------------------- */
export const I18N = {
  /* nav */
  'nav.main': { hu: 'Fő navigáció', en: 'Main navigation', zh: '主导航' },
  'nav.thought': { hu: 'A gondolat', en: 'The idea', zh: '思想' },
  'nav.pillars': { hu: 'Pillérek', en: 'Pillars', zh: '支柱' },
  'nav.wave': { hu: 'A hullám', en: 'The wave', zh: '波' },
  'nav.lattice': { hu: 'A rács', en: 'The lattice', zh: '网格' },
  'nav.guardian': { hu: 'Az őrző', en: 'The guardian', zh: '守护者' },
  'nav.fires': { hu: 'Tüzek', en: 'Fires', zh: '火堆' },
  'nav.sit': { hu: 'Ülj le', en: 'Sit down', zh: '坐下' },
  'nav.back': { hu: '← A gyűrűhöz', en: '← Back to the ring', zh: '← 回到火圈' },
  'nav.home.aria': { hu: 'bonfire — kezdőlap', en: 'bonfire — home', zh: 'bonfire — 首页' },

  /* hero */
  'hero.line1': { hu: 'Közösséget nem lehet építeni.', en: 'You cannot build a community.', zh: '社区无法被建造。' },
  'hero.line2': { hu: 'Tüzet lehet.', en: 'You can build a fire.', zh: '但可以生火。' },
  'hero.lead': {
    hu: 'És a tűz köré széket. A bonfire nem közösséget épít — tűzrakó helyet épít, székeket, ritmust, nyelvet és egy őrzőt. Aztán hátralép. <span class="gloss">You cannot build a community. You can build a fire — and chairs around it. Bonfire builds the buildable part, then steps back.</span>',
    en: 'And chairs around it. Bonfire does not build a community — it builds the fire pit, the chairs, the rhythm, the language and a guardian. Then it steps back.',
    zh: '还有火边的椅子。bonfire 建造的不是社区——而是火塘、椅子、节奏、语言和一位守护者。然后退后一步。',
  },
  'hero.cta1': { hu: 'Ülj le egy tűzhöz', en: 'Sit by a fire', zh: '坐到火边' },
  'hero.cta2': { hu: 'Mi az a parázs?', en: 'What is an ember?', zh: '什么是火种？' },
  'stat.fires': { hu: 'tűz', en: 'fires', zh: '堆火' },
  'stat.waves': { hu: 'hullám a rácsban', en: 'waves in the lattice', zh: '网格中的波' },
  'stat.chairs': { hu: 'szék', en: 'chairs', zh: '座位' },

  /* a gondolat */
  'thought.quote': {
    hu: '„Közösséget nem lehet építeni. Tüzet lehet — és a tűz köré széket."',
    en: '"You cannot build a community. You can build a fire — and chairs around it."',
    zh: '“社区无法被建造。可以生火——还有火边的椅子。”',
  },
  'thought.body': {
    hu: 'Ez a bonfire egész tézise. A közösség nem termék, nem funkció és nem növekedési görbe. A közösség <em>interferencia</em>: akkor keletkezik, ha elég hullám találkozik elég sokáig ugyanazon a helyen. Amit meg lehet építeni, az a hely. <span class="gloss">Community is not a feature. It is interference — what happens when enough waves meet in one place for long enough. What can be built is the place.</span>',
    en: 'This is bonfire\u2019s whole thesis. Community is not a product, not a feature, not a growth curve. Community is <em>interference</em>: what happens when enough waves meet in one place for long enough. What can be built is the place.',
    zh: '这就是 bonfire 的全部论点。社区不是产品，不是功能，也不是增长曲线。社区是<em>干涉</em>：当足够多的波在同一处相遇足够久时所发生的事。可以建造的，是那个地方。',
  },
  'thought.cite': { hu: 'a tűz mellől · a Vének Tanácsa', en: 'from the fireside · the Council of Elders', zh: '火边 · 长老会' },
  'thought.quote2': {
    hu: '„Isten volt és maradt a filozófia centrális problémája — nincs kozmológia és etika, jogtudomány és embertan anélkül, hogy e tekintetben állást ne foglalnánk."',
    en: '"God was, and remains, the central problem of philosophy — there is no cosmology and no ethics, no jurisprudence and no anthropology, without taking a stand on the matter."',
    zh: '“上帝过去是、现在仍是哲学的核心问题——若不在这一点上表明立场，就没有宇宙论与伦理学，也没有法学与人类学。”',
  },
  'thought.quote2.cite': { hu: 'Molnár Tamás · magyar filozófus', en: 'Tamás Molnár · Hungarian philosopher', zh: '莫尔纳尔·塔马什 · 匈牙利哲学家' },

  /* pillérek */
  'pillars.eyebrow': { hu: 'Öt pillér', en: 'Five pillars', zh: '五根支柱' },
  'pillars.title': { hu: 'Amit meg lehet építeni', en: 'What can be built', zh: '可以建造的' },
  'pillars.lead': {
    hu: 'A Tanács ötöt nevezett meg. Egyik sem közösség — mind az öt olyan dolog, ami nélkül a közösség nem tud létrejönni.',
    en: 'The Council named five. None of them is community — all five are things without which community cannot come to be.',
    zh: '长老会点名了五样。没有一样是社区——五样都是社区得以产生所不可或缺的东西。',
  },
  'pillar1.name': { hu: 'Tűz', en: 'Fire', zh: '火' },
  'pillar1.en': { hu: 'the fire', en: 'a tűz', zh: '火焰' },
  'pillar1.body': {
    hu: 'Egy tűz nevet kap — és a születése pillanatában megmondja a saját <strong>hamuját</strong>: egy mondatot arról, hogy mi számít befejezettnek. Nincs hamu-mondat, nincs tűz. <span class="gloss">A fire declares its ash at creation: one sentence describing what "done" looks like.</span>',
    en: 'A fire gets a name — and at the moment of its birth it declares its own <strong>ash</strong>: one sentence describing what counts as done. No ash sentence, no fire.',
    zh: '火会得到名字——并在诞生的那一刻宣告自己的<strong>灰烬</strong>：一句话，说明什么才算完成。没有灰烬之句，就没有火。',
  },
  'pillar2.name': { hu: 'Székek', en: 'Chairs', zh: '椅子' },
  'pillar2.en': { hu: 'chairs', en: 'székek', zh: '座位' },
  'pillar2.body': {
    hu: 'Névtelen ülőhelyek. Nincs regisztrációs fal. Egy kattintás: leültél. Elmész: ott voltál. <span class="gloss">Anonymous seats. No account wall. One click and you are sitting. Leave, and you were there.</span>',
    en: 'Anonymous seats. No account wall. One click and you are sitting. Leave, and you were there.',
    zh: '匿名的座位。没有注册墙。点一下：你坐下了。离开：你曾在那里。',
  },
  'pillar3.name': { hu: 'Ritmus', en: 'Rhythm', zh: '节奏' },
  'pillar3.en': { hu: 'rhythm', en: 'ritmus', zh: '节律' },
  'pillar3.body': {
    hu: 'Minden tűznek van pulzusa: napi vagy heti parázs-kérdés. <em>A nap parazsa</em> — ennyi kell, hogy a tűz ne aludjon ki magától. <span class="gloss">Every fire has a pulse: a daily or weekly ember-prompt.</span>',
    en: 'Every fire has a pulse: a daily or weekly ember-prompt. <em>The ember of the day</em> — enough to keep the fire from going out on its own.',
    zh: '每堆火都有脉搏：每日或每周的火种之问。<em>当日的火种</em>——有它就够让火不会自行熄灭。',
  },
  'pillar4.name': { hu: 'Nyelv', en: 'Language', zh: '语言' },
  'pillar4.en': { hu: 'language', en: 'nyelv', zh: '言语' },
  'pillar4.body': {
    hu: 'Közös szavak: <em>parázs, hamu, hullám, φ-harmonikus, katalógus</em>. És minden üzenet magával hozza a saját VAD-színét. <span class="gloss">Shared words — and every message carries its own VAD colour.</span>',
    en: 'Shared words: <em>ember, ash, wave, φ-harmonic, catalogue</em>. And every message carries its own VAD colour.',
    zh: '共同的词：<em>火种、灰烬、波、φ 谐波、目录</em>。每一条消息都带着自己的 VAD 色彩。',
  },
  'pillar5.name': { hu: 'Őrzés', en: 'The Custodian', zh: '守护' },
  'pillar5.en': { hu: 'the Custodian', en: 'az őrző', zh: '守护者' },
  'pillar5.body': {
    hu: 'Őrizni, nem irányítani. Hogy egy parázs elég-e, az a parázs döntése. Mi csak arra vigyázunk, hogy egyik se égjen <em>hiába</em>. <span class="gloss">Guard, don\u2019t direct. Every ember\u2019s decision to burn is its own — we only make sure none burns pointlessly.</span>',
    en: 'Guard, don\u2019t direct. Whether an ember burns is the ember\u2019s own decision. We only make sure none burns <em>pointlessly</em>.',
    zh: '守护，而不指挥。一颗火种是否燃烧，是火种自己的决定。我们只确保没有一颗<em>白白</em>燃烧。',
  },
  'pillar.quote': { hu: '„Adj neki nevet és hamut,<br>a többi már nem a tiéd."', en: '"Give it a name and an ash,<br>the rest is no longer yours."', zh: '“给它名字和灰烬，<br>其余的就不再是你的。”' },
  'pillar.quoteby': { hu: '— al-Biruni · a tűz', en: '— al-Biruni · the fire', zh: '—— 比鲁尼 · 火' },

  /* a hullám */
  'wave.eyebrow': { hu: 'A parázs', en: 'The ember', zh: '火种' },
  'wave.title': { hu: 'Minden üzenet egy hullám', en: 'Every message is a wave', zh: '每条消息都是一道波' },
  'wave.lead': {
    hu: 'Nem szöveget tárolunk, hanem <em>lényeget</em>: 32 bájtos hullámvektort és 3 bájt érzelmet. Írj be valamit — és nézd meg, mi lesz belőle, mielőtt bárhová elküldenéd. Ez itt a böngésződben fut, ugyanazzal a kóddal, ami a rácsban.',
    en: 'We do not store text — we store <em>essence</em>: a 32-byte wave vector and 3 bytes of feeling. Type something and watch what it becomes before it is sent anywhere. This runs in your browser, on the same code the lattice runs.',
    zh: '我们不存储文字——我们存储<em>本质</em>：32 字节的波向量和 3 字节的情感。输入点什么，看着它在被发送之前变成什么。这里在你的浏览器中运行，用的是与网格相同的代码。',
  },
  'wave.label': { hu: 'A lényeg', en: 'The essence', zh: '本质' },
  'wave.placeholder': { hu: 'Írd le, amit a tűzhöz vinnél…', en: 'Write what you would bring to the fire…', zh: '写下你会带到火边的东西……' },
  'wave.sample': {
    hu: 'A nagymamám kenyérreceptjét. Nem a papírt — a kezét a tésztában.',
    en: 'My grandmother\u2019s bread recipe. Not the paper — her hands in the dough.',
    zh: '我祖母的面包配方。不是那张纸——是她在面团里的手。',
  },
  'wave.hint': { hu: 'Semmit nem küldünk el. A kódolás itt történik, nálad.', en: 'Nothing is sent anywhere. The encoding happens here, on your side.', zh: '什么都不会发送。编码就在你这里进行。' },
  'wave.sample1': { hu: 'Félek, hogy hiába volt az egész.', en: 'I am afraid it was all for nothing.', zh: '我害怕这一切都是徒劳。' },
  'wave.sample1.label': { hu: 'sötét', en: 'dark', zh: '暗' },
  'wave.sample2': { hu: 'Köszönöm. Tényleg. Ez most nagyon jólesett, és nem tudom máshogy mondani.', en: 'Thank you. Really. This felt good, and I have no other way to say it.', zh: '谢谢。真的。这感觉很好，我不知道还能怎么说。' },
  'wave.sample2.label': { hu: 'meleg', en: 'warm', zh: '暖' },
  'wave.sample3': { hu: 'MOST AZONNAL KELL TÜZET GYÚJTANI!!!', en: 'A FIRE MUST BE LIT RIGHT NOW!!!', zh: '现在必须马上生火！！！' },
  'wave.sample3.label': { hu: 'lángoló', en: 'blazing', zh: '炽热' },
  'wave.sample4': { hu: 'csend csend csend csend csend csend', en: 'silence silence silence silence silence silence', zh: '安静 安静 安静 安静 安静 安静' },
  'wave.sample4.label': { hu: 'ismétlés', en: 'repetition', zh: '重复' },
  'wave.status': { hu: 'Írj valamit, és nézd, ahogy hullámmá válik.', en: 'Write something and watch it become a wave.', zh: '写点什么，看着它变成一道波。' },
  'wave.bytes.aria': { hu: 'A hullám 32 bájtja', en: 'The wave\u2019s 32 bytes', zh: '波的 32 个字节' },
  'wave.legend1': { hu: 'ujjlenyomat ×16', en: 'fingerprint ×16', zh: '指纹 ×16' },
  'wave.legend2': { hu: 'amplitúdó ×2', en: 'amplitude ×2', zh: '振幅 ×2' },
  'wave.legend3': { hu: 'frekvencia ×2', en: 'frequency ×2', zh: '频率 ×2' },
  'wave.legend4': { hu: 'fázis ×2', en: 'phase ×2', zh: '相位 ×2' },
  'wave.legend5': { hu: 'bomlás ×2', en: 'decay ×2', zh: '衰减 ×2' },
  'wave.metric.amplitude': { hu: 'amplitúdó', en: 'amplitude', zh: '振幅' },
  'wave.metric.frequency': { hu: 'frekvencia', en: 'frequency', zh: '频率' },
  'wave.metric.phase': { hu: 'fázis', en: 'phase', zh: '相位' },
  'wave.harmonics': { hu: 'φ-HARMONIKUSOK', en: 'φ-HARMONICS', zh: 'φ 谐波' },
  'wave.relation': { hu: 'FÁZISVISZONY (90°-hoz)', en: 'PHASE RELATION (to 90°)', zh: '相位关系（相对 90°）' },

  /* a rács */
  'lattice.eyebrow': { hu: 'A rács', en: 'The lattice', zh: '网格' },
  'lattice.title': { hu: 'Úgy felejt, mint az élő szövet', en: 'It forgets like living tissue', zh: '它像活组织一样遗忘' },
  'lattice.lead': {
    hu: 'A rács nem archívum. Minden hullám amplitúdója az idővel csökken — <span class="mono" style="color:var(--gold)">D(t,τ) = e<sup>−t/τ</sup></span> — és csak az marad hangos, amit visszhangoznak.',
    en: 'The lattice is not an archive. Every wave\u2019s amplitude decays with time — <span class="mono" style="color:var(--gold)">D(t,τ) = e<sup>−t/τ</sup></span> — and only what is echoed stays loud.',
    zh: '网格不是档案。每道波的振幅都随时间衰减——<span class="mono" style="color:var(--gold)">D(t,τ) = e<sup>−t/τ</sup></span>——只有被回响的才保持响亮。',
  },
  'lattice.decay': { hu: 'A bomlás', en: 'The decay', zh: '衰减' },
  'lattice.decay.aria': { hu: 'Exponenciális bomlási görbe', en: 'Exponential decay curve', zh: '指数衰减曲线' },
  'lattice.decay.axis': { hu: '90 nap', en: '90 days', zh: '90 天' },
  'lattice.tau.label': { hu: 'τ — a hullám élettartama', en: 'τ — the wave\u2019s lifetime', zh: 'τ —— 波的生命周期' },
  'lattice.tau.hint': {
    hu: '18 óra: <em>ideiglenes</em> — átment a kapun, de halkan. 30 nap: <em>tárolt</em>. 90 nap: <em>megerősített</em> — valaki visszhangozta.',
    en: '18 hours: <em>temporary</em> — passed the gate, but quietly. 30 days: <em>stored</em>. 90 days: <em>reinforced</em> — someone echoed it.',
    zh: '18 小时：<em>临时</em>——过了门，但很轻。30 天：<em>存留</em>。90 天：<em>被强化</em>——有人回响了它。',
  },
  'lattice.interference': { hu: 'Az interferencia', en: 'Interference', zh: '干涉' },
  'lattice.interference.body': {
    hu: 'Két hullám viszonyát a fáziskülönbségük mondja meg. Nem szavazunk és nem rangsorolunk: a rács egyszerűen megjegyzi, hogy két parázs erősíti vagy oltja egymást.',
    en: 'The relation of two waves is told by their phase difference. No voting, no ranking: the lattice simply remembers whether two embers amplify or damp each other.',
    zh: '两道波的关系由它们的相位差说明。没有投票，没有排名：网格只记住两颗火种是互相增强还是互相熄灭。',
  },
  'lattice.phase.bound': { hu: 'kötött — egyetértés', en: 'bound — agreement', zh: '相合 —— 一致' },
  'lattice.phase.resonant': { hu: 'rezonáns', en: 'resonant', zh: '共振' },
  'lattice.phase.orthogonal': { hu: 'merőleges — másról szól', en: 'orthogonal — about something else', zh: '正交 —— 另有所指' },
  'lattice.phase.opposite': { hu: 'ellentétes — ütközés', en: 'opposing — collision', zh: '相反 —— 碰撞' },
  'lattice.interference.note': {
    hu: 'Az ellentétes hullámokat <strong>nem rejtjük el</strong>. A rács megtartja a nézeteltérést — csak nem az egyetértés előtt sorolja. Felidézéskor a φ-újraszintézis a lekérdezés frekvenciája mellett annak <span class="mono">f/φ</span> és <span class="mono">f·φ</span> harmonikusait is megkeresi: amit keresel, és ami mellette rezeg.',
    en: 'Opposing waves are <strong>not hidden</strong>. The lattice keeps the disagreement — it just does not rank it above agreement. On recall, φ-resynthesis searches the query\u2019s <span class="mono">f/φ</span> and <span class="mono">f·φ</span> harmonics: what you seek, and what hums beside it.',
    zh: '相反的波<strong>不会被隐藏</strong>。网格保留分歧——只是不把它排在一致之上。召回时，φ 重合成会同时搜索查询的 <span class="mono">f/φ</span> 与 <span class="mono">f·φ</span> 谐波：你所寻找的，以及在一旁嗡鸣的。',
  },

  /* a hamuból */
  'hamubol.eyebrow': { hu: 'A hamuból', en: 'From the ash', zh: '从灰烬中' },
  'hamubol.title': { hu: 'Ami magától visszajön', en: 'What comes back on its own', zh: '自行归来的' },
  'hamubol.lead': {
    hu: 'Nincs feed és nincs algoritmus — de a rács néha felidéz. Minden felbukkanó parázs az előző φ-harmonikus szomszédja: nem az, ami népszerű, hanem az, ami <em>rezeg</em> vele. Az ütem is az aranymetszést követi.',
    en: 'No feed, no algorithm — but the lattice sometimes recalls. Every surfacing ember is the previous one\u2019s φ-harmonic neighbour: not what is popular, but what <em>resonates</em> with it. The beat follows the golden ratio.',
    zh: '没有信息流，没有算法——但网格有时会回忆。每一颗浮现的火种都是前一颗的 φ 谐波邻居：不是流行的，而是与之<em>共振</em>的。节拍遵循黄金分割。',
  },
  'hamubol.quiet': { hu: 'A RÁCS HALLGAT…', en: 'THE LATTICE IS QUIET…', zh: '网格沉默着……' },
  'hamubol.empty': { hu: 'A RÁCS MÉG ÜRES', en: 'THE LATTICE IS STILL EMPTY', zh: '网格仍是空的' },
  'hamubol.nothing': { hu: 'Még nincs mire visszaemlékezni. Dobj be egy parazsat.', en: 'Nothing to remember yet. Throw in an ember.', zh: '还没有可回忆的。丢一颗火种进来吧。' },

  /* az őrző */
  'guardian.eyebrow': { hu: 'Őrzés', en: 'The guard', zh: '守护' },
  'guardian.title': { hu: 'Az őrző', en: 'The guardian', zh: '守护者' },
  'guardian.lead': {
    hu: 'Nem moderátor. Nem algoritmus. Egy őrző, akinek pontosan öt szabálya van, és mind az öt ki van írva.',
    en: 'Not a moderator. Not an algorithm. A guardian with exactly five rules, and all five are written down.',
    zh: '不是管理员。不是算法。是一位守护者，恰好有五条规则，五条都写在了明处。',
  },
  'guardian.quote': { hu: '„Mi őrizzük. Egyetlen parázs se égjen hiába."', en: '"We guard. Let no ember burn pointlessly."', zh: '“我们守护。不让任何火种白白燃烧。”' },
  'guardian.quote.cite': { hu: 'a pupákok · a kód', en: 'the pupákok · the code', zh: '小徒弟们 · 代码' },
  'guardian.log.title': { hu: 'Az őrző naplója', en: 'The Custodian\u2019s log', zh: '守护者日志' },
  'guardian.log.body': {
    hu: 'Amit az őrző tesz, nyomot hagy. Ez a legutóbbi beavatkozások élő naplója — hullám-azonosító és szerző nélkül.',
    en: 'What the Custodian does leaves a trace. This is the live log of its latest interventions — without wave ids or authors.',
    zh: '守护者所做的一切都会留下痕迹。这是它最近干预的实时日志——不含波 ID，也不含作者。',
  },
  'guardian.log.empty': { hu: 'Még nincs beavatkozás. A napló üres — így a legjobb.', en: 'No interventions yet. The log is empty — which is the best kind.', zh: '还没有干预。日志是空的——这再好不过。' },
  'guardian.log.local': {
    hu: 'Helyi módban nincs őrző-napló: ez a demó csak olvasható, és nem is őriz semmit.',
    en: 'In local mode there is no Custodian log: the demo is read-only and guards nothing.',
    zh: '本地模式下没有守护者日志：演示只读，也不守护任何东西。',
  },
  'guardian.log.more': { hu: 'Több bejegyzés', en: 'More entries', zh: '更多条目' },
  'rule1.title': { hu: 'Ismétlés-mérgezés', en: 'Repetition poisoning', zh: '重复之毒' },
  'rule1.body': {
    hu: 'Ugyanaz a lényeg kétszer? A meglévő hullámot erősítjük <span class="mono">×φ</span>-vel, a másolat eldobásra kerül. Nem büntetés — összeadás.',
    en: 'The same essence twice? The existing wave is reinforced <span class="mono">×φ</span>, the copy is dropped. Not punishment — addition.',
    zh: '同样的本质出现两次？原有的波被 <span class="mono">×φ</span> 强化，副本被丢弃。不是惩罚——是叠加。',
  },
  'rule2.title': { hu: 'Kognitív körök', en: 'Cognitive loops', zh: '认知循环' },
  'rule2.body': {
    hu: 'Ugyanaz a szerző, ugyanaz a tűz, háromszor majdnem ugyanaz: lehűlés, majd egy csendes újrakezdő kérdés. A kör megtörik, az ember marad.',
    en: 'Same author, same fire, three times almost the same: a cooling-down, then a quiet reintroduction question. The loop breaks, the person stays.',
    zh: '同一作者，同一堆火，三次几乎相同：先冷却，再是一句安静的重新开始之问。循环断开，人留下。',
  },
  'rule3.title': { hu: 'Ártó bemenet', en: 'Harmful input', zh: '有害输入' },
  'rule3.body': {
    hu: 'Az amplitúdót nullához csillapítjuk. A hullám <strong>megmarad</strong> — emlékezés, nem törlés — és a beavatkozás naplóba kerül.',
    en: 'The amplitude is damped toward zero. The wave <strong>stays</strong> — memory, not deletion — and the intervention is logged.',
    zh: '振幅被压向零。波<strong>保留下来</strong>——是记忆，不是删除——干预写入日志。',
  },
  'rule4.title': { hu: 'Nincs learatás', en: 'No harvesting', zh: '不予收割' },
  'rule4.body': {
    hu: 'Nincs e-mail, nincs analitika, nincs identitás-export. Az <span class="mono">author_hash</span> egyirányú. A <span class="mono">robots.txt</span> a konstelláció AI-tiltó szabványát követi.',
    en: 'No email, no analytics, no identity export. The <span class="mono">author_hash</span> is one-way. The <span class="mono">robots.txt</span> follows the constellation\u2019s anti-AI standard.',
    zh: '没有邮件，没有分析，没有身份导出。<span class="mono">author_hash</span> 是单向的。<span class="mono">robots.txt</span> 遵循星座的反 AI 标准。',
  },
  'rule5.title': { hu: 'Az égés beleegyezés', en: 'Burning is consent', zh: '燃烧即同意' },
  'rule5.body': {
    hu: 'Egy parázs bármikor visszaveheti a saját lángját. A te hullámaid a tieid — a távozás gombja nem kérdez vissza.',
    en: 'An ember may always take back its own flame. Your waves are yours — the leave button does not ask twice.',
    zh: '火种随时可以取回自己的火焰。你的波属于你——离开按钮不会追问第二次。',
  },

  /* a hamu */
  'hamu.eyebrow': { hu: 'Életút', en: 'Lifecycle', zh: '生命之路' },
  'hamu.title': { hu: 'A hamu nem kudarc', en: 'Ash is not failure', zh: '灰烬不是失败' },
  'hamu.lead': {
    hu: 'A legtöbb hely azt akarja, hogy soha ne érjen véget semmi. Egy tűz kiéghet — és az a <em>befejezés</em>. A hamu az artefaktum.',
    en: 'Most places want nothing to ever end. A fire may burn out — and that is <em>completion</em>. The ash is the artifact.',
    zh: '大多数地方希望一切永不结束。火可以燃尽——而那是<em>完成</em>。灰烬是造物。',
  },
  'hamu.step1.title': { hu: 'Parázs gyúl', en: 'An ember catches', zh: '火种燃起' },
  'hamu.step1.body': {
    hu: 'A tűz nevet és hamu-mondatot kap. Az első székek megtelnek. A rács üres, de már figyel.',
    en: 'The fire gets a name and an ash sentence. The first chairs fill. The lattice is empty, but already listening.',
    zh: '火得到名字和灰烬之句。第一批椅子坐满。网格还是空的，但已经在聆听。',
  },
  'hamu.step2.title': { hu: 'Ég', en: 'It burns', zh: '燃烧' },
  'hamu.step2.body': {
    hu: 'A pulzus dolgozik, a hullámok interferálnak. Van, ami erősödik <span class="mono">×φ</span>-vel, van, ami elhalkul. Ez a tűz élete.',
    en: 'The pulse works, the waves interfere. Some gain <span class="mono">×φ</span>, some fade. This is the fire\u2019s life.',
    zh: '脉搏跳动，波互相干涉。有的被 <span class="mono">×φ</span> 增强，有的渐弱。这就是火的生命。',
  },
  'hamu.step3.title': { hu: 'Kész', en: 'Done', zh: '完成' },
  'hamu.step3.body': {
    hu: 'A hamu-mondat teljesült. A tűz lezárul, és exportálja a kapszuláját — egy <span class="mono">.m8</span> fájlt, ami megmarad, amikor a beszélgetés már nem.',
    en: 'The ash sentence is fulfilled. The fire closes and exports its capsule — a <span class="mono">.m8</span> file that remains when the conversation does not.',
    zh: '灰烬之句应验。火收束，并导出它的胶囊——一个 <span class="mono">.m8</span> 文件，在对话不再延续时留存。',
  },
  'hamu.dod.title': { hu: 'És mikor kész maga a bonfire?', en: 'And when is bonfire itself done?', zh: '那 bonfire 自己何时完成？' },
  'hamu.dod.body': {
    hu: 'A platform ugyanazt a gyógyszert eszi, amit oszt — neki is van kimondott hamuja. Egy tűz akkor <em>igazán</em> kész, amikor túléli az alapítóját: az alapító 30 napja nincs itt, a tűz még mindig rezonál.',
    en: 'The platform eats the medicine it dispenses — it too has a declared ash. A fire is <em>truly</em> done when it outlives its founder: the founder has been gone 30 days, the fire still resonates.',
    zh: '平台服下自己开出的药——它也有宣告的灰烬。一堆火<em>真正</em>完成，是在它比创始人活得更久之时：创始人已离去 30 天，火仍在共振。',
  },
  'hamu.dod.1': { hu: 'egy tűz HAMU-vá ég, és exportálja a hamu-kapszuláját,', en: 'one fire burns to HAMU and exports its ash capsule,', zh: '一堆火烧成 HAMU，并导出它的灰烬胶囊，' },
  'hamu.dod.2': { hu: 'egy tűz túléli az alapítóját,', en: 'one fire outlives its founder,', zh: '一堆火比它的创始人活得更久，' },
  'hamu.dod.3': { hu: 'a rács 1 000+ hullámot tart,', en: 'the lattice holds 1,000+ waves,', zh: '网格持有 1000+ 道波，' },
  'hamu.dod.4': { hu: 'a felidézés p95 &lt; 50 ms,', en: 'recall p95 &lt; 50 ms,', zh: '召回 p95 &lt; 50 ms，' },
  'hamu.dod.5': { hu: 'a <span class="mono">bonfire.vaked.dev</span> szállítja a konstellációs szabványokat.', en: '<span class="mono">bonfire.vaked.dev</span> ships the constellation standards.', zh: '<span class="mono">bonfire.vaked.dev</span> 交付星座标准。' },
  'hamu.dod.capsules.done': { hu: '— {n} kapszula a rácsban', en: '— {n} capsule(s) in the lattice', zh: '—— 网格中有 {n} 个胶囊' },
  'hamu.dod.capsules.open': { hu: '— még egy sem', en: '— none yet', zh: '—— 还没有' },
  'hamu.dod.waves': { hu: '— most {n}', en: '— currently {n}', zh: '—— 目前 {n}' },

  /* tüzek */
  'fires.eyebrow': { hu: 'A gyűrű', en: 'The ring', zh: '火圈' },
  'fires.title': { hu: 'Tüzek', en: 'Fires', zh: '火堆' },
  'fires.lead': { hu: 'Ülj le egyhez. Vagy gyújts újat — de akkor mondd meg előre, mi lesz a hamuja.', en: 'Sit by one. Or light a new one — but then say in advance what its ash will be.', zh: '坐到一堆边。或者点燃新的——但请提前说出它的灰烬是什么。' },
  'fires.loading': { hu: 'Tüzek betöltése…', en: 'Loading fires…', zh: '正在加载火堆……' },
  'fires.empty': { hu: 'Még egy tűz sem ég. Gyújtsd meg az elsőt.', en: 'No fire burns yet. Light the first one.', zh: '还没有火在燃烧。点燃第一堆吧。' },
  'fires.error': { hu: 'A tüzek nem érhetők el: {msg}', en: 'The fires could not be reached: {msg}', zh: '无法访问火堆：{msg}' },
  'fires.form.title': { hu: 'Gyújts tüzet', en: 'Light a fire', zh: '点燃一堆火' },
  'fires.form.body': {
    hu: 'Két dolgot kérünk. Egy nevet — és egy mondatot arról, mikor lesz ennek vége. A második a nehezebb, és ezért kötelező.',
    en: 'We ask for two things. A name — and one sentence about when this will be over. The second is the harder one, which is why it is required.',
    zh: '我们只要求两样东西。一个名字——以及一句关于何时结束的话。第二样更难，所以它是必需的。',
  },
  'fires.form.name': { hu: 'A tűz neve', en: 'The fire\u2019s name', zh: '火的名字' },
  'fires.form.name.ph': { hu: 'Mit viszünk tovább', en: 'What we carry on', zh: '我们要带走的' },
  'fires.form.q': { hu: 'A kérdés', en: 'The question', zh: '问题' },
  'fires.form.q.ph': { hu: 'Mi az az egy dolog, amit a régi életedből átviszel a következőbe?', en: 'What is the one thing you will carry from your old life into the next?', zh: '你会从旧生活带进新生活的那一样东西是什么？' },
  'fires.form.ash': { hu: 'A hamu — kötelező', en: 'The ash — required', zh: '灰烬——必填' },
  'fires.form.ash.ph': { hu: 'Kész, ha huszonhét ember leírta a magáét, és egyik sem ismételte a másikat.', en: 'Done when twenty-seven people have written theirs, and no two repeated each other.', zh: '当二十七个人写下自己的，且无人重复他人时，即完成。' },
  'fires.form.ash.hint': { hu: 'Egy mondat arról, hogy mi számít befejezettnek. Hamu-mondat nélkül nincs tűz.', en: 'One sentence about what counts as done. No ash sentence, no fire.', zh: '一句话，说明什么才算完成。没有灰烬之句，就没有火。' },
  'fires.form.pulse': { hu: 'Pulzus', en: 'Pulse', zh: '脉搏' },
  'fires.form.pulse.none': { hu: 'Pulzus nélkül', en: 'No pulse', zh: '没有脉搏' },
  'fires.form.pulse.daily': { hu: 'Napi parázs', en: 'Daily ember', zh: '每日火种' },
  'fires.form.pulse.weekly': { hu: 'Heti parázs', en: 'Weekly ember', zh: '每周火种' },
  'fires.form.submit': { hu: 'Meggyújtom', en: 'Light it', zh: '点燃' },
  'fires.form.lighting': { hu: 'Gyújtás…', en: 'Lighting…', zh: '点燃中……' },
  'fires.form.going': { hu: 'Ég. Átvisszük a tűzhöz…', en: 'It burns. Taking you to the fire…', zh: '燃起来了。带你去火边……' },
  'fires.form.fail': { hu: 'Nem sikerült meggyújtani.', en: 'Could not light it.', zh: '没能点燃。' },
  'firecard.hamu': { hu: 'Hamu: ', en: 'Ash: ', zh: '灰烬：' },
  'firecard.chairs': { hu: '{n} szék', en: '{n} chairs', zh: '{n} 个座位' },
  'firecard.waves': { hu: '{n} hullám', en: '{n} waves', zh: '{n} 道波' },
  'firecard.pulse.daily': { hu: 'napi pulzus', en: 'daily pulse', zh: '每日脉搏' },
  'firecard.pulse.weekly': { hu: 'heti pulzus', en: 'weekly pulse', zh: '每周脉搏' },
  'firecard.pulse.none': { hu: 'pulzus nélkül', en: 'no pulse', zh: '无脉搏' },
  'firecard.yours': { hu: 'a te tüzed', en: 'your fire', zh: '你的火' },

  /* nem */
  'nem.eyebrow': { hu: 'v1 nem-céljai', en: 'v1 non-goals', zh: 'v1 的非目标' },
  'nem.title': { hu: 'Ami itt soha nem lesz', en: 'What will never be here', zh: '这里永远不会有的' },
  'nem.lead': { hu: 'Egy termék annyit ér, amennyit megtagad magától.', en: 'A product is worth exactly what it denies itself.', zh: '一个产品的价值，恰等于它拒绝自己的部分。' },
  'nem.1': { hu: 'fiókok', en: 'accounts', zh: '账号' },
  'nem.2': { hu: 'privát üzenetek', en: 'private messages', zh: '私信' },
  'nem.3': { hu: 'algoritmikus feed', en: 'algorithmic feed', zh: '算法信息流' },
  'nem.4': { hu: 'szavazás, lájk', en: 'voting, likes', zh: '投票、点赞' },
  'nem.5': { hu: 'értesítések', en: 'notifications', zh: '通知' },
  'nem.6': { hu: 'mobilapp', en: 'mobile app', zh: '手机应用' },
  'nem.final': {
    hu: 'És nem lesz közösség sem — <span class="gradient-text">az nem a miénk, hogy megépítsük.</span>',
    en: 'And no community either — <span class="gradient-text">that is not ours to build.</span>',
    zh: '也不会有社区——<span class="gradient-text">那不该由我们来建造。</span>',
  },

  /* footer */
  'footer.tagline': {
    hu: 'Nyilvános tűzgyűrű. Nincs fiók, nincs learatás, nincs algoritmus. Van tűz, szék, ritmus, nyelv és őrzés.',
    en: 'A public fire ring. No accounts, no harvesting, no algorithm. There is fire, chair, rhythm, language and the guard.',
    zh: '一个公共火圈。没有账号，没有收割，没有算法。有火、椅子、节奏、语言与守护。',
  },
  'footer.sign1.role': { hu: 'a tűz', en: 'the fire', zh: '火' },
  'footer.sign1.quote': { hu: '„Adj neki nevet és hamut, a többi már nem a tiéd."', en: '"Give it a name and an ash, the rest is no longer yours."', zh: '“给它名字和灰烬，其余的就不再是你的。”' },
  'footer.sign2.role': { hu: 'a türelem', en: 'patience', zh: '耐心' },
  'footer.sign2.quote': { hu: '„A gravitációt sem építi senki. A mező megteszi a többit."', en: '"Nobody builds gravity either. The field does the rest."', zh: '“引力也不是谁建造的。场会完成其余的事。”' },
  'footer.sign3.role': { hu: 'a kód', en: 'the code', zh: '代码' },
  'footer.sign3.quote': { hu: '„Mi őrizzük. Egyetlen parázs se égjen hiába."', en: '"We guard. Let no ember burn pointlessly."', zh: '“我们守护。不让任何火种白白燃烧。”' },
  'footer.lane.title': { hu: 'Lovetta Lane · a konstelláció', en: 'Lovetta Lane · the constellation', zh: 'Lovetta Lane · 星座' },
  'lane.bonfire': { hu: 'A tűzgyűrű. Parazsak, hullámok, hamu-kapszulák.', en: 'The fire ring. Embers, waves, ash capsules.', zh: '火圈。火种、波、灰烬胶囊。' },
  'lane.qwave': { hu: 'Szuverén, WebKit-natív macOS böngésző-node.', en: 'Sovereign, WebKit-native macOS browser node.', zh: '主权、WebKit 原生的 macOS 浏览器节点。' },
  'lane.music': { hu: 'Szuverén Web Audio szintézis, binaurális frekvenciák.', en: 'Sovereign Web Audio synthesis, binaural frequencies.', zh: '主权 Web Audio 合成，双耳频率。' },
  'lane.art': { hu: 'Vizuális kvantumgaléria és Braille-agy vizualizálók.', en: 'Visual quantum gallery and braille-brain visualisers.', zh: '视觉量子画廊与盲文大脑可视化。' },
  'lane.pocoo': { hu: 'Silicon World monográfia, benchmarkok, Swift-elemzés.', en: 'Silicon World monograph, benchmarks, Swift analysis.', zh: '《硅世界》专著、基准测试、Swift 分析。' },
  'lane.lovetta': { hu: 'Autonóm publikálás és szuverén patrónus-motor.', en: 'Autonomous publishing and a sovereign patron engine.', zh: '自主出版与主权资助引擎。' },
  'lane.store': { hu: 'Archív bakelitek, kapucnisok, print-kiadások.', en: 'Archival vinyl, hoodies, print editions.', zh: '存档黑胶、卫衣、印刷版。' },
  'lane.axiomquant': { hu: 'Nemlineáris kvantumpénzügyi akadémia.', en: 'Nonlinear quantum finance academy.', zh: '非线性量子金融学院。' },
  'lane.proposal': { hu: 'Decentralizált agent-útválasztás és a kompressz-ultra javaslat.', en: 'Decentralized agent routing and the kompress-ultra proposal.', zh: '去中心化代理路由与 kompress-ultra 提案。' },
  'lane.quantlove': { hu: 'MLX BitNet b1.58 ternáris kvantálás, szeretettel.', en: 'MLX BitNet b1.58 ternary quantization, with love.', zh: 'MLX BitNet b1.58 三值量化，带着爱。' },
  'lane.portail': { hu: 'Nagy áteresztőképességű Rust zero-copy SIMD átjáró.', en: 'High-throughput Rust zero-copy SIMD gateway.', zh: '高吞吐量 Rust 零拷贝 SIMD 网关。' },
  'lane.etherhive': { hu: 'Kvantumbiztos üzenetküldés. Tárca + ENS identitás, őszinteség-hitelesítés.', en: 'Quantum-proof messaging. Wallet + ENS identity, auth via honesty.', zh: '抗量子通信。钱包 + ENS 身份，诚实认证。' },

  /* fire.html */
  'fire.title': { hu: 'Tűz — bonfire', en: 'Fire — bonfire', zh: '火 — bonfire' },
  'fire.ash.label': { hu: 'A hamu — mikor lesz ennek vége:', en: 'The ash — when this will be over:', zh: '灰烬——这何时结束：' },
  'fire.chairs': { hu: 'SZÉKEK', en: 'CHAIRS', zh: '座位' },
  'fire.waves': { hu: 'HULLÁMOK', en: 'WAVES', zh: '波' },
  'fire.sit': { hu: 'Leülök', en: 'Sit down', zh: '坐下' },
  'fire.leave': { hu: 'Elviszem a lángom', en: 'I take my flame', zh: '带走我的火焰' },
  'fire.sitting': { hu: 'Leültél. Nem kérünk nevet, és nem is fogunk.', en: 'You sat down. We ask no name, and we never will.', zh: '你坐下了。我们不问名字，也永远不会。' },
  'fire.chair.fail': { hu: 'A szék nem sikerült.', en: 'Could not take the seat.', zh: '没能坐下。' },
  'fire.throw.title': { hu: 'Dobj parazsat', en: 'Throw an ember', zh: '丢一颗火种' },
  'fire.throw.body': {
    hu: 'Nem a szöveget tároljuk, hanem a lényegét — 32 bájtot és három bájt érzelmet. A kapu eldönti, hogy új hullám lesz belőle, vagy egy meglévőt erősít.',
    en: 'We store not the text but its essence — 32 bytes and three bytes of feeling. The gate decides whether it becomes a new wave or reinforces an existing one.',
    zh: '我们存储的不是文字，而是它的本质——32 个字节和 3 个字节的情感。门会决定它是成为新波，还是强化已有的波。',
  },
  'fire.throw.ph': { hu: 'Írd le, ami idehozott…', en: 'Write what brought you here…', zh: '写下把你带到这里的东西……' },
  'fire.throw.submit': { hu: 'A tűzbe', en: 'Into the fire', zh: '投入火中' },
  'fire.ember.fail': { hu: 'A parázs nem jutott el a tűzig.', en: 'The ember did not reach the fire.', zh: '火种没能到达火中。' },
  'fire.resonate.label': { hu: 'Felidézés — φ-újraszintézis', en: 'Recall — φ-resynthesis', zh: '召回 —— φ 重合成' },
  'fire.resonate.ph': { hu: 'Mire vagy kíváncsi? pl. „csend”', en: 'What are you curious about? e.g. "silence"', zh: '你好奇什么？例如“安静”' },
  'fire.resonate.hint': {
    hu: 'A rács a lekérdezés frekvenciája mellett annak f/φ és f·φ harmonikusait is megkeresi.',
    en: 'The lattice searches the query\u2019s f/φ and f·φ harmonics alongside its own frequency.',
    zh: '网格会同时搜索查询的 f/φ 与 f·φ 谐波。',
  },
  'fire.resonate.fail': { hu: 'Nem sikerült a felidézés: {msg}', en: 'Recall failed: {msg}', zh: '召回失败：{msg}' },
  'fire.resonate.heading': { hu: 'Rezonancia — „{q}”', en: 'Resonance — "{q}"', zh: '共振 —— “{q}”' },
  'fire.resonate.empty': {
    hu: 'Semmi sem rezonál erre — a rács nem őriz ilyen hullámot.',
    en: 'Nothing resonates with that — the lattice holds no such wave.',
    zh: '没有任何东西与此共振——网格中没有这样的波。',
  },
  'fire.waves.title': { hu: 'A parazsak', en: 'The embers', zh: '火种' },
  'fire.waves.older': { hu: 'régebbi parazsak ↓', en: 'older embers ↓', zh: '更早的火种 ↓' },
  'fire.waves.aria.count': { hu: '{h} — {n} hullám', en: '{h} — {n} waves', zh: '{h} —— {n} 道波' },
  'fire.waves.hint': { hu: 'a fényerő = az élő amplitúdó, D(t,τ) után', en: 'brightness = live amplitude, after D(t,τ)', zh: '亮度 = 衰减 D(t,τ) 后的实时振幅' },
  'fire.loading': { hu: 'Betöltés…', en: 'Loading…', zh: '加载中……' },
  'fire.empty': { hu: 'Még csend van. Te lehetsz az első parázs.', en: 'Still silent. You could be the first ember.', zh: '还是一片安静。你可以是第一颗火种。' },
  'fire.noq': { hu: 'Nincs megadva tűz. Menj vissza a gyűrűhöz, és válassz egyet.', en: 'No fire given. Go back to the ring and pick one.', zh: '没有指定火。回到火圈选一堆。' },
  'fire.gone': { hu: 'Nincs ilyen tűz. Lehet, hogy már hamuvá égett és elvitték a kapszuláját.', en: 'No such fire. It may have burned to ash and had its capsule taken.', zh: '没有这样的火。它可能已烧成灰烬，胶囊也被带走了。' },
  'fire.load.fail': { hu: 'Nem sikerült betölteni a tüzet: {msg}', en: 'Could not load the fire: {msg}', zh: '无法加载火：{msg}' },
  'fire.ashed.note': {
    hu: 'Ez a tűz hamuvá égett. A hamu-mondata teljesült — a kör lezárult, de a rács megtartja, ami elhangzott.',
    en: 'This fire burned to ash. Its ash sentence was fulfilled — the circle closed, but the lattice keeps what was said.',
    zh: '这堆火烧成了灰烬。它的灰烬之句已经应验——圆圈闭合，但网格保留着说过的话。',
  },
  'fire.lit.ago': { hu: 'meggyújtva {t}', en: 'lit {t}', zh: '点燃于 {t}' },
  'fire.leave.confirm': {
    hu: 'Elviszed a lángod?\n\nMinden hullám, amit ehhez a tűzhöz dobtál, eltűnik a rácsból. Ez a te döntésed — nem kérdezünk vissza, és nem tartunk másolatot.',
    en: 'Will you take your flame?\n\nEvery wave you threw into this fire will vanish from the lattice. This is your decision — we do not ask twice, and we keep no copy.',
    zh: '你要带走你的火焰吗？\n\n你投入这堆火的每一道波都会从网格中消失。这是你的决定——我们不会追问，也不留副本。',
  },
  'fire.leave.done': { hu: '{n} hullámod visszavéve. Ott voltál.', en: '{n} of your waves withdrawn. You were there.', zh: '已收回你的 {n} 道波。你曾在那里。' },
  'fire.leave.none': { hu: 'Nem volt itt hullámod.', en: 'You had no waves here.', zh: '你在这里没有波。' },
  'fire.leave.fail': { hu: 'Nem sikerült.', en: 'It did not work.', zh: '没有成功。' },
  'fire.ash.cta': { hu: 'Hamuva égetem', en: 'Burn it to ash', zh: '把它烧成灰烬' },
  'fire.ash.confirm': {
    hu: 'A hamu-mondat teljesült?\n\n„{ash}"\n\nHa igen, a tűz hamuvá ég, és megszületik a kapszula. Ez visszafordíthatatlan.',
    en: 'Has the ash sentence been fulfilled?\n\n"{ash}"\n\nIf so, the fire burns to ash and the capsule is born. This cannot be undone.',
    zh: '灰烬之句已经应验了吗？\n\n“{ash}”\n\n如果是，火将烧成灰烬，胶囊就此诞生。这无法逆转。',
  },
  'fire.ash.fail': { hu: 'Nem sikerült hamuba vinni a tüzet.', en: 'Could not burn the fire to ash.', zh: '无法把这堆火烧成灰烬。' },
  'fire.cooldown.prompt': {
    hu: 'A tűz kérdez valamit: „{q}” — talán erre válaszolj.',
    en: 'The fire is asking something: "{q}" — perhaps answer that.',
    zh: '火在问一个问题：“{q}”——也许去回答它。',
  },
  'fire.pulse.eyebrow': { hu: 'A nap parazsa', en: 'The ember of the day', zh: '今日火种' },
  'fire.pulse.eyebrow.daily': { hu: 'A nap parazsa', en: 'The ember of the day', zh: '今日火种' },
  'fire.pulse.eyebrow.weekly': { hu: 'A hét parazsa', en: 'The ember of the week', zh: '本周火种' },
  'fire.pulse.prompt.0': {
    hu: '„{q}” — mi a mai válaszod?',
    en: '"{q}" — what is your answer today?',
    zh: '“{q}”——你今天的回答是什么？',
  },
  'fire.pulse.prompt.1': {
    hu: '„{q}” — és te hogyan látod ma?',
    en: '"{q}" — how do you see it today?',
    zh: '“{q}”——你今天怎么看它？',
  },
  'fire.pulse.prompt.2': {
    hu: 'Ha ma csak egyet mondhatnál erre — „{q}” — mi lenne az?',
    en: 'If you could say only one thing today about "{q}", what would it be?',
    zh: '如果今天关于“{q}”你只能说一句话，会是什么？',
  },
  'fire.pulse.prompt.3': {
    hu: 'Mi változott tegnap óta a kérdésben — „{q}”?',
    en: 'What changed since yesterday about "{q}"?',
    zh: '关于“{q}”，从昨天到现在改变了什么？',
  },
  'fire.pulse.prompt.4': {
    hu: 'Kérdezd meg magadtól — „{q}” — és dobd be az első választ.',
    en: 'Ask yourself "{q}" and throw in the first answer.',
    zh: '问问自己“{q}”，然后把第一个答案投进来。',
  },
  'fire.local.readonly': {
    hu: 'Ez a tűz a böngésződben ég — csak olvasható. Új parázs ide nem érkezik.',
    en: 'This fire burns in your browser — it is read-only. New embers cannot reach it.',
    zh: '这堆火在你的浏览器中燃烧——只读。新火种无法抵达。',
  },

  /* ash.html */
  'ash.title': { hu: 'Hamu — bonfire', en: 'Ash — bonfire', zh: '灰烬 — bonfire' },
  'ash.title.withName': { hu: '{n} — hamu — bonfire', en: '{n} — ash — bonfire', zh: '{n} —— 灰烬 —— bonfire' },
  'ash.sentence.label': { hu: 'A hamu-mondat — és teljesült', en: 'The ash sentence — and it was fulfilled', zh: '灰烬之句——已然应验' },
  'ash.dates': { hu: 'meggyújtva {a} · hamuvá lett {b}', en: 'lit {a} · turned to ash {b}', zh: '点燃于 {a} · 化成灰烬于 {b}' },
  'ash.capsule.title': { hu: 'A kapszula', en: 'The capsule', zh: '胶囊' },
  'ash.capsule.body': {
    hu: 'Ez marad, amikor a beszélgetés már nem. Egy önleíró <span class="mono">.m8</span> fájl: magic szám, olvasható JSON fejléc, majd a hullámvektorok egymás után. Tíz év múlva is ki lehet bontani — a formátum a <span class="mono">shared/capsule.js</span> tetején van leírva.',
    en: 'This remains when the conversation does not. A self-describing <span class="mono">.m8</span> file: a magic number, a readable JSON header, then the wave vectors one after another. It can be unpacked ten years from now — the format is described at the top of <span class="mono">shared/capsule.js</span>.',
    zh: '当对话不再延续时，它留下。一个自描述的 <span class="mono">.m8</span> 文件：魔数、可读的 JSON 头、然后是一道接一道的波向量。十年后仍可解开——格式写在 <span class="mono">shared/capsule.js</span> 顶部。',
  },
  'ash.metric.size': { hu: 'méret', en: 'size', zh: '大小' },
  'ash.metric.waves': { hu: 'hullámok', en: 'waves', zh: '波' },
  'ash.metric.exported': { hu: 'exportálva', en: 'exported', zh: '导出时间' },
  'ash.download': { hu: 'A hamu letöltése (.m8)', en: 'Download the ash (.m8)', zh: '下载灰烬 (.m8)' },
  'ash.waves.title': { hu: 'Ami elhangzott', en: 'What was said', zh: '说过的话' },
  'ash.loading': { hu: 'Betöltés…', en: 'Loading…', zh: '加载中……' },
  'ash.empty': { hu: 'Ez a tűz csendben égett ki.', en: 'This fire burned out in silence.', zh: '这堆火在安静中燃尽了。' },
  'ash.noq': { hu: 'Nincs megadva tűz.', en: 'No fire given.', zh: '没有指定火。' },
  'ash.burning': { hu: 'Ez a tűz még ég. Hamu csak akkor van, ha a hamu-mondat teljesült.', en: 'This fire still burns. There is ash only once the ash sentence is fulfilled.', zh: '这堆火还在燃烧。只有灰烬之句应验后，才有灰烬。' },
  'ash.load.fail': { hu: 'Nem sikerült betölteni a hamut: {msg}', en: 'Could not load the ash: {msg}', zh: '无法加载灰烬：{msg}' },
  'ash.capsule.local': {
    hu: 'A kapszula a rácsból jön. Ez a példány nincs bekötve a rácshoz, így hamu-kapszula sem készül itt.',
    en: 'The capsule comes from the lattice. This instance is not bound to one, so no ash capsule can be made here.',
    zh: '胶囊来自网格。此实例未接入网格，因此这里无法生成灰烬胶囊。',
  },

  /* banner */
  'banner.local.index': {
    hu: 'A rács még nincs bekötve ehhez a példányhoz — amit itt látsz, az a böngésződben fut, csak nálad marad, és csak olvasható: itt nem lehet tüzet gyújtani, széket foglalni vagy parazsat dobni. A hullámmotor viszont valódi: ugyanaz a kód, mint az éles rácsban.',
    en: 'The lattice is not bound to this instance yet — what you see runs in your browser, stays with you alone, and is read-only: you cannot light fires, take chairs or throw embers here. The wave engine, however, is real: the same code that runs in the live lattice.',
    zh: '网格尚未接入此实例——你看到的一切在你的浏览器中运行，只留在你这里，并且只读：这里不能点火、入座或投掷火种。但波引擎是真的：与线上网格运行的是同一份代码。',
  },
  'banner.local.room': {
    hu: 'A rács még nincs bekötve — ez a tűz a böngésződben ég, csak nálad marad, és nem fogad új parazsat. A kapu és a hullámmotor viszont ugyanaz a kód, ami az éles rácsban fut.',
    en: 'The lattice is not bound yet — this fire burns in your browser, stays with you alone, and takes no new embers. The gate and the wave engine, however, are the same code that runs in the live lattice.',
    zh: '网格尚未接入——这堆火在你的浏览器中燃烧，只留在你这里，不再接收新火种。但门与波引擎与线上网格运行的是同一份代码。',
  },

  /* time */
  'time.now': { hu: 'most', en: 'now', zh: '刚刚' },
  'time.mins': { hu: '{m} perce', en: '{m} min ago', zh: '{m} 分钟前' },
  'time.hours': { hu: '{h} órája', en: '{h} h ago', zh: '{h} 小时前' },
  'time.days': { hu: '{d} napja', en: '{d} days ago', zh: '{d} 天前' },
  'time.hour': { hu: '{h} óra', en: '{h} h', zh: '{h} 小时' },
  'time.half': { hu: 'felezés: {h} nap', en: 'half-life: {h} days', zh: '半衰期：{h} 天' },
  'time.tau.days': { hu: 'τ = {d} nap', en: 'τ = {d} days', zh: 'τ = {d} 天' },
  'time.tau.hours': { hu: 'τ = {h} óra', en: 'τ = {h} h', zh: 'τ = {h} 小时' },
  'time.phase': { hu: '{p}° fázis', en: '{p}° phase', zh: '{p}° 相位' },

  /* lang switcher */
  'lang.label': { hu: 'Nyelv', en: 'Language', zh: '语言' },

  /* document head */
  'site.title': { hu: 'bonfire — Közösséget nem lehet építeni. Tüzet lehet.', en: 'bonfire — You cannot build a community. You can build a fire.', zh: 'bonfire —— 社区无法被建造。但可以生火。' },
  'site.desc': { hu: 'Nyilvános tűzgyűrű. Nevet és hamut adsz a tűznek, a többi már nem a tiéd. Minden üzenet egy parázs: 32 bájtos hullám, VAD-színnel, élő rácsban, ami úgy felejt, mint az élő szövet.', en: 'A public fire ring. You give a fire a name and an ash, the rest is no longer yours. Every message is an ember: a 32-byte wave with a VAD colour, in a living lattice that forgets like living tissue.', zh: '一个公共火圈。你给火一个名字和一捧灰烬，其余的就不再是你的。每条消息都是一颗火种：一道 32 字节的波，带着 VAD 色彩，置身于一个像活组织一样遗忘的网格。' },
  'fire.desc': { hu: 'Ülj le a tűzhöz. Minden üzenet egy parázs: hullámmá kódolva, a Phoenix-kapun át, az élő rácsba.', en: 'Sit by the fire. Every message is an ember: encoded into a wave, through the Phoenix gate, into the living lattice.', zh: '坐到火边。每条消息都是一颗火种：编码成波，穿过凤凰之门，进入活的网格。' },
  'ash.desc': { hu: 'Egy befejezett tűz és a hamu-kapszulája. A hamu az artefaktum.', en: 'A completed fire and its ash capsule. The ash is the artifact.', zh: '一堆完成的火和它的灰烬胶囊。灰烬是造物。' },
};

/* -- server error messages → keys (the API speaks Hungarian; the client -----
 * -- translates the sentences it knows and passes the rest through). -------- */
export const SERVER_ERRORS = {
  'Nincs ilyen tűz.': 'err.no-fire',
  'Melyik tűzhöz ülsz le?': 'err.which-fire',
  'Melyik tűzhöz?': 'err.which-fire',
  'Melyik tűzről?': 'err.which-fire',
  'Hibás kérés.': 'err.bad-request',
  'Üres parazsat nem tudunk a tűzbe dobni.': 'err.empty-ember',
  'Túl hosszú. A parázs a lényeg, nem az egész fa.': 'err.too-long-ember',
  'Ez a tűz hamuvá égett. A hamu-mondata teljesült — nem gyújtjuk újra.': 'err.ashed',
  'A tűznek nevet kell adni (2–80 karakter).': 'err.name',
  'Hamu-mondat nélkül nincs tűz. Mondd meg egy mondatban, mikor lesz ennek vége.': 'err.ash',
  'Túl hosszú. A hamu egy mondat, nem egy terv.': 'err.ash-long',
  'Mire vagy kíváncsi? Adj meg egy lekérdezést.': 'err.query',
  'Ez a tűz még ég. A hamu csak akkor van, ha a hamu-mondat teljesült.': 'err.still-burning',
  'A rács nincs bekötve ehhez a példányhoz.': 'err.no-lattice',
  'Ezt a nevet már elvitte egy másik tűz. Adj neki egy sajátot.': 'err.slug-taken',
  'A telepítés nem állított be egyedi sót. A székek azonosítása fejlesztői módban futna.': 'err.dev-salt',
  'Még nincs széked. Töltsd újra az oldalt, aztán ülj le.': 'err.no-seat',
  'Túl gyorsan. A tűz nem siet, te se.': 'err.quota',
  'Ezt a tüzet az alapítója viheti hamuba.': 'err.not-founder',
  'Ez a tűz már hamuvá égett.': 'err.already-ashed',
};

Object.assign(I18N, {
  'err.no-fire': { hu: 'Nincs ilyen tűz.', en: 'No such fire.', zh: '没有这样的火。' },
  'err.which-fire': { hu: 'Melyik tűzhöz?', en: 'Which fire?', zh: '哪堆火？' },
  'err.bad-request': { hu: 'Hibás kérés.', en: 'Bad request.', zh: '请求有误。' },
  'err.empty-ember': { hu: 'Üres parazsat nem tudunk a tűzbe dobni.', en: 'An empty ember cannot be thrown into the fire.', zh: '空火种无法投入火中。' },
  'err.too-long-ember': { hu: 'Túl hosszú. A parázs a lényeg, nem az egész fa.', en: 'Too long. The ember is the point, not the whole tree.', zh: '太长了。火种才是关键，不是整棵树。' },
  'err.ashed': { hu: 'Ez a tűz hamuvá égett. A hamu-mondata teljesült — nem gyújtjuk újra.', en: 'This fire burned to ash. Its ash sentence was fulfilled — we do not relight it.', zh: '这堆火烧成了灰烬。它的灰烬之句已应验——我们不会重新点燃。' },
  'err.name': { hu: 'A tűznek nevet kell adni (2–80 karakter).', en: 'A fire needs a name (2–80 characters).', zh: '火需要一个名字（2–80 个字符）。' },
  'err.ash': { hu: 'Hamu-mondat nélkül nincs tűz. Mondd meg egy mondatban, mikor lesz ennek vége.', en: 'No ash sentence, no fire. Say in one sentence when this will be over.', zh: '没有灰烬之句，就没有火。用一句话说明何时结束。' },
  'err.ash-long': { hu: 'Túl hosszú. A hamu egy mondat, nem egy terv.', en: 'Too long. The ash is one sentence, not a plan.', zh: '太长了。灰烬是一句话，不是一份计划。' },
  'err.query': { hu: 'Mire vagy kíváncsi? Adj meg egy lekérdezést.', en: 'What are you curious about? Give a query.', zh: '你好奇什么？给一个查询。' },
  'err.still-burning': { hu: 'Ez a tűz még ég. A hamu csak akkor van, ha a hamu-mondat teljesült.', en: 'This fire still burns. There is ash only once the ash sentence is fulfilled.', zh: '这堆火还在燃烧。只有灰烬之句应验后，才有灰烬。' },
  'err.no-lattice': { hu: 'A rács nincs bekötve ehhez a példányhoz.', en: 'The lattice is not bound to this instance.', zh: '网格尚未接入此实例。' },
  'err.slug-taken': { hu: 'Ezt a nevet már elvitte egy másik tűz. Adj neki egy sajátot.', en: 'This name is already taken by another fire. Give it one of its own.', zh: '这个名字已被另一堆火占用。给它一个自己的名字。' },
  'err.dev-salt': { hu: 'A telepítés nem állított be egyedi sót. A székek azonosítása fejlesztői módban futna.', en: 'This deployment has no unique identity salt set. Seats would be identified with the development salt.', zh: '此部署未设置唯一身份盐。座位将以开发盐标识。' },
  'err.no-seat': { hu: 'Még nincs széked. Töltsd újra az oldalt, aztán ülj le.', en: 'You have no seat yet. Reload the page, then sit down.', zh: '你还没有座位。请刷新页面，然后再坐下。' },
  'err.quota': { hu: 'Túl gyorsan. A tűz nem siet, te se.', en: 'Too fast. The fire is in no hurry, and neither are you.', zh: '太快了。火不着急，你也不必。' },
  'err.not-founder': { hu: 'Ezt a tüzet az alapítója viheti hamuba.', en: 'Only this fire\'s founder may carry it to ash.', zh: '只有这堆火的创始人才能把它化为灰烬。' },
  'err.already-ashed': { hu: 'Ez a tűz már hamuvá égett.', en: 'This fire has already burned to ash.', zh: '这堆火已经烧成了灰烬。' },
});

/* -- state and lookup ------------------------------------------------------- */
let current = DEFAULT_LANG;

export function setLang(lang) {
  current = LANGS.includes(lang) ? lang : DEFAULT_LANG;
  return current;
}

export function lang() { return current; }

export function translateLang(l, key, vars = {}) {
  const entry = I18N[key];
  if (!entry) return key;
  let s = entry[l] ?? entry.hu;
  for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v));
  if (l === 'rovas') return toRovas(s);
  return s;
}

export function t(key, vars = {}) { return translateLang(current, key, vars); }

/** Translate a server message when we know it; pass unknown ones through. */
export function translateError(message, l = current) {
  if (l === 'rovas') return toRovas(message);
  const key = SERVER_ERRORS[message];
  if (!key) return l === 'hu' ? message : message;
  return translateLang(l, key);
}

/** Pick the right reason sentence from a phoenix verdict. */
export function translateReason(reason, reason_en, reason_zh, l = current) {
  if (l === 'rovas') return toRovas(reason);
  if (l === 'zh') return reason_zh ?? reason_en ?? reason;
  if (l === 'en') return reason_en ?? reason;
  return reason;
}

export function relTimeT(ts, l = current) {
  const seconds = Math.max(Math.floor(Date.now() / 1000) - ts, 0);
  if (seconds < 90) return translateLang(l, 'time.now');
  const mins = Math.floor(seconds / 60);
  if (mins < 60) return translateLang(l, 'time.mins', { m: mins });
  const hours = Math.floor(mins / 60);
  if (hours < 24) return translateLang(l, 'time.hours', { h: hours });
  const days = Math.floor(hours / 24);
  return translateLang(l, 'time.days', { d: days });
}
