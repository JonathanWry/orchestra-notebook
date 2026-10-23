const demoFrame = document.querySelector("#demoApp");

function scoreSnippet(title, accent, variant = 0) {
  const noteSets = [
    [[145,48],[190,63],[238,43],[294,70],[354,51],[415,37],[474,57],[540,44],[604,69]],
    [[130,67],[180,51],[225,61],[280,39],[338,55],[402,72],[467,49],[531,58],[596,35]],
    [[136,42],[197,58],[258,72],[318,47],[380,62],[442,41],[502,67],[570,51],[628,38]]
  ];
  const notes = noteSets[variant % noteSets.length].map(([x,y], index) =>
    `<g transform="translate(${x} ${y}) rotate(-16)"><ellipse rx="8" ry="5.5" fill="${accent}"/><path d="M7 0V-30" stroke="${accent}" stroke-width="2"/></g>${index % 3 === 1 ? `<path d="M${x+7} ${y-30} Q${x+30} ${y-40} ${x+48} ${y-25}" fill="none" stroke="${accent}" stroke-width="2"/>` : ""}`
  ).join("");
  const staff = [36,50,64,78,92].map(y => `<path d="M36 ${y}H684" stroke="#9ea8a3" stroke-width="1"/>`).join("");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="720" height="128" viewBox="0 0 720 128"><rect width="720" height="128" rx="10" fill="#fffefa"/><text x="35" y="21" font-family="Georgia,serif" font-size="11" fill="#68736e">${title}</text>${staff}<text x="47" y="82" font-family="Georgia,serif" font-size="50" fill="#334c48">𝄞</text>${notes}<path d="M360 30V100" stroke="#d8ddd8"/><path d="M680 30V100" stroke="#7f8b86"/></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

function activities(seed, start = 1, end = 32) {
  return Array.from({ length: end - start + 1 }, (_, index) => {
    const measure = start + index;
    const wave = ((measure * (seed + 3)) % 13) / 13;
    return { measure, density: Math.min(.96, .18 + wave * .72) };
  });
}

function analysis(melody, chord, bass, percussion, texture, description = "") {
  return {
    melodyText: melody, melody: melody.split(" + "),
    chordText: chord, chord: chord.split(" + "),
    bassText: bass, bass: bass.split(" + "),
    percussionText: percussion, percussion: percussion ? percussion.split(" + ") : [],
    cadenza: {
      enabled: Boolean(texture), text: texture, instruments: texture ? texture.split(" + ") : [],
      description, snippets: []
    }
  };
}

function demoLibrary() {
  const daphnisSnippet = scoreSnippet("Daphnis et Chloé · Lever du jour", "#385f59", 0);
  const firebirdSnippet = scoreSnippet("The Firebird · Danse infernale", "#b65f3c", 1);
  const scoreLink = (scoreId, scoreTitle, path, start, end, snippet = null) => ({
    id: `link-${scoreId}-${start}`, scoreId, scoreTitle, path, start, end, snippet
  });
  const daphnisPath = "/Users/demo/Scores/Ravel - Daphnis et Chloe.mscz";
  const firebirdPath = "/Users/demo/Scores/Stravinsky - The Firebird.mscz";
  return {
    version: 8,
    customInstruments: ["Celesta", "Bass Clarinet"],
    order: ["daphnis", "firebird"],
    scores: {
      daphnis: {
        score: {
          id: "daphnis", title: "Daphnis et Chloé · Suite No. 2", composer: "Maurice Ravel",
          subtitle: "Lever du jour · orchestration study", path: daphnisPath, measureCount: 148, pageCount: 42,
          markers: [{ measure: 1, text: "A" }, { measure: 9, text: "B" }, { measure: 17, text: "C" }, { measure: 25, text: "D" }],
          parts: [
            { name: "Flute 1", shortName: "Fl. 1", group: "木管", activities: activities(1) },
            { name: "Flute 2", shortName: "Fl. 2", group: "木管", activities: activities(4) },
            { name: "Oboe 1", shortName: "Ob. 1", group: "木管", activities: activities(7) },
            { name: "Clarinet 1", shortName: "Cl. 1", group: "木管", activities: activities(2) },
            { name: "Horn 1–4", shortName: "Hn. 1–4", group: "铜管", activities: activities(5) },
            { name: "Harp 1", shortName: "Hp. 1", group: "键盘 / 竖琴", activities: activities(8) },
            { name: "Timpani", shortName: "Timp.", group: "打击乐", activities: activities(10) },
            { name: "Violin 1", shortName: "Vln. 1", group: "弦乐", activities: activities(3) },
            { name: "Viola", shortName: "Vla.", group: "弦乐", activities: activities(6) },
            { name: "Cello", shortName: "Vc.", group: "弦乐", activities: activities(9) },
            { name: "Contrabass", shortName: "Cb.", group: "弦乐", activities: activities(11) }
          ]
        },
        notes: [
          {
            id: "dawn", kind: "analysis", title: "黎明：从静态织体中长出旋律", moodText: "quiet, luminous, suspended",
            content: "<p>低弦保持几乎无方向性的运动，木管不是突然进入，而是从同一片音色里逐层显影。</p><blockquote>关注密度增长，而不只是音量增长。</blockquote>",
            analysis: analysis("Flute 1 + Flute 2 + Oboe 1", "Violin 1 + Viola", "Cello + Contrabass", "Timpani", "Harp 1 + Flute 1", "竖琴分解音型与木管短句共同形成闪烁的前景 texture。"),
            links: [scoreLink("daphnis", "Daphnis et Chloé · Suite No. 2", daphnisPath, 1, 12, daphnisSnippet)],
            updatedAt: "2026-10-22T18:10:00Z"
          },
          {
            id: "crescendo", kind: "analysis", title: "渐强不是加倍，而是逐层换景", moodText: "expansive, determined",
            content: "<p>先让圆号补足和声中部，再让小提琴接入旋律；高潮前才增加铜管低声部。</p>",
            analysis: analysis("Oboe 1 + Clarinet 1 + Violin 1", "Horn 1–4 + Viola", "Cello + Contrabass", "Timpani", "Flute 1 + Harp 1"),
            links: [scoreLink("daphnis", "Daphnis et Chloé · Suite No. 2", daphnisPath, 21, 32)],
            updatedAt: "2026-10-21T20:45:00Z"
          },
          {
            id: "flute-color", kind: "free", title: "长笛与竖琴的边缘融合", moodText: "delicate, floating",
            content: "<h2>听感</h2><p>竖琴起音提供轮廓，长笛延长余韵；两者不是同音色加倍，而是前后景交接。</p>",
            analysis: analysis("", "", "", "", "Harp 1 + Flute 1", "记录可移植的音色组合。"),
            links: [scoreLink("daphnis", "Daphnis et Chloé · Suite No. 2", daphnisPath, 44, 48)],
            updatedAt: "2026-10-20T16:30:00Z"
          }
        ]
      },
      firebird: {
        score: {
          id: "firebird", title: "The Firebird · 1919 Suite", composer: "Igor Stravinsky",
          subtitle: "Danse infernale · rhythm and color", path: firebirdPath, measureCount: 196, pageCount: 58,
          markers: [{ measure: 1, text: "Danse" }, { measure: 9, text: "11" }, { measure: 17, text: "12" }, { measure: 25, text: "13" }],
          parts: [
            { name: "Piccolo", shortName: "Picc.", group: "木管", activities: activities(6) },
            { name: "Bass Clarinet", shortName: "B. Cl.", group: "木管", activities: activities(9) },
            { name: "Trumpet 1", shortName: "Tpt. 1", group: "铜管", activities: activities(2) },
            { name: "Trombone", shortName: "Tbn.", group: "铜管", activities: activities(5) },
            { name: "Bass Drum", shortName: "B. Dr.", group: "打击乐", activities: activities(8) },
            { name: "Violin 1", shortName: "Vln. 1", group: "弦乐", activities: activities(3) },
            { name: "Cello", shortName: "Vc.", group: "弦乐", activities: activities(11) }
          ]
        },
        notes: [
          {
            id: "infernal", kind: "analysis", title: "重音链与骤然腾空的 Texture", moodText: "violent, angular, brilliant",
            content: "<p>打击乐负责切割时间，铜管给出垂直重量；高木管的跑动把重音之间的空隙连接起来。</p>",
            analysis: analysis("Piccolo + Trumpet 1", "Trumpet 1 + Trombone", "Cello + Bass Clarinet", "Bass Drum", "Piccolo + Violin 1", "快速上行材料不是独立旋律，而是把垂直重音组织成连续 texture。"),
            links: [scoreLink("firebird", "The Firebird · 1919 Suite", firebirdPath, 8, 18, firebirdSnippet)],
            updatedAt: "2026-10-19T22:20:00Z"
          }
        ]
      }
    }
  };
}

demoFrame.addEventListener("load", () => {
  const app = demoFrame.contentWindow;
  app.receiveLibrary(demoLibrary());
  const view = new URLSearchParams(location.search).get("view") || "overview";
  if (view === "overview") return;
  app.document.querySelector("[data-score-id]")?.click();
  if (view === "map") app.document.querySelector('[data-view="map"]')?.click();
  if (view === "editor") {
    const firstCard = app.document.querySelector("#noteGrid .note-card");
    firstCard?.querySelector('[data-do="edit"]')?.click();
  }
});
