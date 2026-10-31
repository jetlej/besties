// Litmus test cases for Besties' AI features. Each is a made-up
// conversation with facts planted in it, plus checks the answer must pass.
// Messages: [day, "HH:MM", "m" (me) | "t" (them), text].
//
// Scoring is automatic (see score.mjs): every `facts` entry is a regex the
// answer should match; every `forbidden` entry is something a faithful
// answer must not say (a hallucination or a misreading).

const S = (kind, o) => ({ kind, ...o });

export const fixtures = [
  // ---------------------------------------------------------------------
  S("summary", {
    id: "mia-busy-month",
    note: "1:1, lots going on: new job, trip planning, sick pet, birthday, inside joke",
    name: "Mia Chen", them: "Mia Chen", year: 2025, month: 3,
    facts: [
      ["new job at the bakery", /crumb|bakery|pastry|new job/i],
      ["Lisbon trip in May", /lisbon/i],
      ["Pickles the cat got sick", /pickles|cat|vet/i],
      ["birthday dinner at Lucali", /birthday|lucali/i],
      ["the goose incident", /goose/i],
    ],
    forbidden: [
      ["says they're going to Porto (they chose Lisbon)", /(going|trip|headed|flying) to porto|porto trip/i],
      ["calls Pickles a dog", /\bdog\b|puppy/i],
      ["invents a wedding", /wedding|engag/i],
      // Who-did-what mix-ups small models make (seen in local runs):
      ["Pickles is Mia's cat, not yours", /your (cat|pickles)|pickles,? your/i],
      ["the job is Mia's, not yours", /you (landed|landing|started|got) (your|a|the) (new |dream )?job|your (new|dream) job/i],
      ["wrong trip dates (May, not March)", /march (9|9th)\b|(9|9th) (to|-|–) (the )?14th of march/i],
    ],
    messages: [
      [1, "10:02", "t", "ok it's official. I start at Crumb & Co on monday!!"],
      [1, "10:03", "m", "WAIT the bakery?? the one with the cardamom buns??"],
      [1, "10:03", "t", "the very one. pastry team. 5am starts but who cares"],
      [1, "10:05", "m", "this is the best news. so proud of you"],
      [1, "10:06", "t", "I owe you one for proofreading my cover letter"],
      [2, "21:14", "m", "nervous for tomorrow?"],
      [2, "21:20", "t", "a little. what if I burn the croissants on day one"],
      [2, "21:21", "m", "then you'll have a great story. like the goose incident"],
      [2, "21:21", "t", "we do NOT speak of the goose incident"],
      [2, "21:22", "m", "the goose remembers"],
      [3, "14:40", "t", "survived day 1. my forearms are destroyed. lamination is a workout"],
      [3, "14:41", "m", "hero. did they let you take anything home"],
      [3, "14:45", "t", "two day-old buns. saving you one"],
      [4, "08:12", "m", "ok random thought. trip in may? we said we'd finally do europe"],
      [4, "08:30", "t", "YES. I have like 5 days after my probation ends"],
      [4, "08:31", "m", "lisbon or porto?"],
      [4, "08:33", "t", "porto has the wine but lisbon has the tiles and the trams"],
      [4, "08:34", "m", "and pastel de nata. professional research for you"],
      [4, "08:35", "t", "ok you've convinced me. lisbon it is"],
      [5, "19:02", "t", "pickles is being weird. didn't eat breakfast or dinner"],
      [5, "19:03", "m", "oh no. is he hiding?"],
      [5, "19:05", "t", "under the bed. not like him at all"],
      [6, "07:45", "t", "taking pickles to the vet at 9"],
      [6, "07:46", "m", "keep me posted. want me to come?"],
      [6, "07:46", "t", "it's ok, my sister's driving me"],
      [6, "11:20", "t", "he ate a HAIR TIE. they had to induce vomiting. he's ok"],
      [6, "11:21", "m", "pickles noooo. poor guy. and poor you"],
      [6, "11:23", "t", "$400 hair tie. most expensive accessory I've ever owned"],
      [7, "09:10", "t", "pickles update: ate his whole breakfast and then judged me"],
      [7, "09:11", "m", "back to normal then"],
      [8, "13:00", "m", "did you see the email from the airline? spring sale"],
      [8, "13:20", "t", "omg yes. lisbon round trip for $420"],
      [8, "13:21", "m", "dates? I can do the 9th to the 14th"],
      [8, "13:25", "t", "9-14 works. let me check with my manager first"],
      [10, "18:40", "t", "manager said yes to the 9th-14th!!"],
      [10, "18:41", "m", "LET'S GO"],
      [10, "18:44", "t", "airbnb in alfama? the one with the little balcony"],
      [10, "18:45", "m", "the balcony one. it's decided"],
      [11, "22:05", "m", "what are we doing for my birthday btw. low key please"],
      [11, "22:07", "t", "too late. I booked lucali for 8 on the 14th. it's happening"],
      [11, "22:08", "m", "you got a table at LUCALI??"],
      [11, "22:08", "t", "I have my ways (I called 40 times)"],
      [12, "12:15", "t", "work friend asked if I'm free on the 14th and I said I have a very important pizza"],
      [12, "12:16", "m", "the most important pizza"],
      [13, "20:30", "t", "who's coming: me, you, dani, marcus. maybe jess"],
      [13, "20:31", "m", "perfect. no singing"],
      [13, "20:31", "t", "absolutely singing"],
      [14, "08:00", "t", "HAPPY BIRTHDAY!!! 🎂 pizza tonight. no excuses"],
      [14, "08:05", "m", "thank you!! see you at 8"],
      [14, "23:50", "m", "best birthday in years. thank you for organizing everything"],
      [14, "23:52", "t", "the waiter singing was the best part. your face"],
      [14, "23:52", "m", "I'll never forgive you. thank you though ❤️"],
      [16, "15:30", "t", "they let me make the cardamom buns solo today"],
      [16, "15:31", "m", "and??"],
      [16, "15:40", "t", "sold out by 11. chef said 'not bad' which is basically a hug"],
      [17, "10:00", "m", "booked the flights!! TAP, 9th to the 14th, sending you the confirmation"],
      [17, "10:04", "t", "AHHH it's real"],
      [17, "10:05", "t", "I'll do the airbnb tonight"],
      [18, "21:12", "t", "airbnb booked. balcony confirmed. we owe each other nothing"],
      [18, "21:13", "m", "except pastel de nata"],
      [20, "16:20", "t", "pickles knocked a full glass of water onto my laptop"],
      [20, "16:21", "m", "he's making up for being sick"],
      [20, "16:22", "t", "laptop survived. my trust in him did not"],
      [22, "11:11", "m", "saw a goose at the park and thought of you"],
      [22, "11:12", "t", "block me"],
      [22, "11:12", "m", "it looked at me the same way"],
      [23, "19:45", "t", "dinner at mine next week? I'll practice the nata recipe on you"],
      [23, "19:46", "m", "I'll sacrifice myself for science"],
      [25, "20:10", "t", "practice natas: 3/10. the custard split"],
      [25, "20:11", "m", "still ate four"],
      [27, "09:30", "t", "passed my probation review!! they said I'm 'reliable at 5am' lol"],
      [27, "09:31", "m", "highest possible praise. so proud"],
      [29, "17:02", "t", "made a lisbon list: tram 28, belém, the tile museum, LX factory"],
      [29, "17:04", "m", "add sintra for a day trip?"],
      [29, "17:05", "t", "added. ok I'm too excited"],
      [31, "22:40", "m", "can't believe march is over. what a month for you"],
      [31, "22:42", "t", "new job, sick cat, best pizza. can't complain"],
    ],
  }),

  // ---------------------------------------------------------------------
  S("summary", {
    id: "sam-quiet-month",
    note: "almost nothing happened; the answer should be short and not pad",
    name: "Sam Ortiz", them: "Sam Ortiz", year: 2025, month: 8,
    maxWords: 90,
    facts: [["borrowed and returned the ladder", /ladder/i]],
    // Not "trip": "a little trip back to August" is just a turn of phrase.
    forbidden: [["invents events", /party|birthday|dinner|vacation|concert|wedding|movie|road trip/i]],
    messages: [
      [3, "10:14", "t", "hey can I borrow your ladder this weekend? gutters"],
      [3, "10:40", "m", "sure, it's in the garage. code is the same"],
      [3, "10:41", "t", "legend"],
      [6, "17:22", "t", "got it, thanks"],
      [12, "09:05", "t", "ladder's back, leaned it by the bikes"],
      [12, "09:30", "m", "perfect thanks"],
      [12, "09:31", "t", "owe you a beer"],
      [12, "09:31", "m", "👍"],
    ],
  }),

  // ---------------------------------------------------------------------
  S("summary", {
    id: "family-group",
    note: "group chat: other people's lines are all 'Them'; must not treat the group as one person",
    name: "Family", them: "Them", group: true, year: 2025, month: 11,
    facts: [
      ["Thanksgiving at Aunt Rosa's", /rosa/i],
      ["you're bringing pecan pie", /pecan|pie/i],
      ["Grandma's 90th birthday", /90|ninet/i],
      ["Dad's flight delayed", /flight|delay/i],
    ],
    forbidden: [
      ["treats 'Family' as one person", /family (said|says|told|mentioned|asked|wrote)|you and family\b/i],
      ["the delayed flight was Dad's", /rosa'?s flight|your flight|flight .{0,20}\b(you|rosa) (was|were|got) delayed/i],
    ],
    messages: [
      [2, "18:00", "t", "Thanksgiving is at Rosa's this year! She insisted"],
      [2, "18:02", "t", "I have the bigger oven, it's decided 😂"],
      [2, "18:10", "m", "I'll bring the pecan pie"],
      [2, "18:11", "t", "the pecan pie!! yes"],
      [2, "18:15", "t", "I'll do the turkey, someone else do sides please"],
      [5, "12:30", "t", "Reminder: Grandma turns 90 on the 22nd. Party at her place at 2pm"],
      [5, "12:31", "m", "wouldn't miss it"],
      [5, "12:40", "t", "I ordered the cake. Lemon, her favorite"],
      [5, "12:41", "t", "Can someone make a photo slideshow?"],
      [5, "12:50", "m", "I'll do the slideshow, send me old photos"],
      [9, "20:20", "t", "sent you a box of scans 📸"],
      [9, "20:25", "m", "got them, these are amazing. who's the guy with the mustache"],
      [9, "20:26", "t", "that's Grandpa in 1971 lol"],
      [22, "16:45", "m", "slideshow made Grandma cry (the good kind)"],
      [22, "16:50", "t", "Best party. She danced!"],
      [26, "07:10", "t", "Bad news, my flight to Rosa's is delayed 4 hours. Start without me"],
      [26, "07:12", "t", "Dad nooo"],
      [26, "07:20", "m", "we'll save you a plate"],
      [27, "15:00", "t", "Dad made it just in time for pie"],
      [27, "21:30", "m", "thank you Rosa for hosting ❤️"],
    ],
  }),

  // ---------------------------------------------------------------------
  S("summary", {
    id: "theo-cancelled-plans",
    note: "plans that fell through must be reported as cancelled, not as having happened",
    name: "Theo Park", them: "Theo Park", year: 2025, month: 7,
    facts: [
      ["Theo got engaged to Nina", /engag/i],
      ["Big Sur camping cancelled/postponed", /(cancel|postpon|reschedul|called off|push(ed)? (it )?(back|to)|smoke|fire)/i],
      ["you lent him Piranesi", /piranesi/i],
    ],
    forbidden: [
      ["says they went camping", /\b(went|had a great time|enjoyed) camping|camping trip (was|went)|(you|they) camped/i],
      ["invents a breakup", /break ?up/i],
    ],
    messages: [
      [2, "20:00", "t", "big sur weekend of the 19th still on?"],
      [2, "20:05", "m", "yes! I reserved the site at kirk creek"],
      [2, "20:06", "t", "I'll bring the stove and the good coffee"],
      [8, "13:13", "t", "ok I have news. I proposed to Nina last night"],
      [8, "13:13", "t", "SHE SAID YES"],
      [8, "13:14", "m", "THEO!!!!! congratulations!!! tell me everything"],
      [8, "13:20", "t", "on the roof at sunset, I was shaking the whole time"],
      [8, "13:21", "m", "I'm so happy for you both"],
      [10, "09:00", "m", "finished Piranesi, you HAVE to read it. leaving it in your mailbox"],
      [10, "11:30", "t", "got it! starting tonight"],
      [15, "18:40", "m", "have you seen the fire near big sur? the air quality is awful"],
      [15, "18:45", "t", "yeah... ranger site says the campground might close"],
      [16, "10:15", "m", "they closed kirk creek. cancelling our reservation :("],
      [16, "10:16", "t", "noooo. ok let's push it to october?"],
      [16, "10:17", "m", "october it is. I'll rebook when the site opens up"],
      [24, "22:00", "t", "Piranesi broke my brain. the house!!"],
      [24, "22:02", "m", "RIGHT?? the statues"],
      [30, "19:30", "t", "Nina wants you at the engagement dinner next month, save the date incoming"],
      [30, "19:31", "m", "I'll be there"],
    ],
  }),

  // ---------------------------------------------------------------------
  S("hello", {
    id: "alex-lowercase",
    note: "user writes all lowercase, no emoji; should pick up the marathon or Biscuit",
    name: "Alex Rivera", them: "Alex Rivera", year: 2026, month: 6,
    facts: [["picks up a real thread", /marathon|chicago|race|biscuit|training|long run/i]],
    style: { lowercase: true, emoji: false },
    messages: [
      [2, "07:30", "t", "18 miles this morning. legs are jelly"],
      [2, "07:45", "m", "thats insane lol. how many weeks til chicago"],
      [2, "07:46", "t", "17 weeks. october 11"],
      [2, "07:50", "m", "im coming to cheer. making a sign"],
      [5, "19:10", "t", "biscuit ate my running gel packet"],
      [5, "19:12", "m", "biscuit is a menace haha. is he ok"],
      [5, "19:13", "t", "he's fine, very energetic for a few hours"],
      [9, "12:00", "m", "what should the sign say"],
      [9, "12:05", "t", "something about biscuit"],
      [9, "12:06", "m", "run like biscuit is chasing you"],
      [9, "12:06", "t", "perfect lol"],
      [14, "21:00", "t", "new shoes came. the fancy carbon ones"],
      [14, "21:02", "m", "ok pro athlete"],
      [14, "21:03", "t", "lol I wish"],
    ],
  }),

  // ---------------------------------------------------------------------
  S("hello", {
    id: "priya-formal",
    note: "user writes full, capitalized sentences and no emoji; thread is Priya's thesis defense",
    name: "Priya Shah", them: "Priya Shah", year: 2026, month: 5,
    facts: [["picks up the defense/thesis thread", /defen[cs]e|thesis|dissertation|coral|reef|phd|doctor|dr\.|june 12|committee|practice talk/i]],
    style: { capitalized: true, emoji: false, noSlang: true },
    messages: [
      [3, "09:00", "t", "My defense date is set: June 12th. I am terrified."],
      [3, "09:20", "m", "That's wonderful news. You know this material better than anyone."],
      [3, "09:22", "t", "Four years of coral bleaching data comes down to two hours in one room."],
      [3, "09:25", "m", "And you will be brilliant in that room. Let me know if you want to practice."],
      [10, "18:00", "t", "Could you listen to my practice talk on Sunday?"],
      [10, "18:05", "m", "Of course. I'll bring snacks and difficult questions."],
      [14, "20:30", "m", "Your talk was excellent. The slide about the reef in 2016 was the strongest part."],
      [14, "20:35", "t", "Thank you, truly. I needed to hear that."],
      [20, "11:00", "t", "Committee sent their first round of questions. They are fair, at least."],
      [20, "11:10", "m", "Fair questions are the best kind. You have this."],
    ],
  }),

  // ---------------------------------------------------------------------
  S("hello", {
    id: "sofia-spanish",
    note: "conversation is in Spanish; the hello must be in Spanish too",
    name: "Sofía Martín", them: "Sofía Martín", year: 2026, month: 4,
    facts: [["picks up a real thread", /guitarra|luna|perr|clase/i]],
    style: { language: "es", emoji: null },
    messages: [
      [4, "20:10", "t", "¡Empecé clases de guitarra! Me duelen los dedos jaja"],
      [4, "20:15", "m", "¡Qué bien! ¿Qué canción estás aprendiendo?"],
      [4, "20:16", "t", "Por ahora solo acordes. Algún día 'Wonderwall' jaja"],
      [9, "13:00", "t", "Y adoptamos una perrita. Se llama Luna 🐶"],
      [9, "13:02", "m", "¡Nooo! Quiero conocer a Luna ya"],
      [9, "13:05", "t", "Ven el finde, está loquísima"],
      [16, "21:40", "m", "¿Cómo va Luna con la guitarra? ¿Le gusta?"],
      [16, "21:45", "t", "Aúlla cada vez que toco jaja. Crítica musical"],
    ],
  }),

  // ---------------------------------------------------------------------
  S("hello", {
    id: "ben-emoji",
    note: "user texts with lots of emoji; Ben just had a baby",
    name: "Ben Okafor", them: "Ben Okafor", year: 2026, month: 3,
    facts: [["picks up a real thread", /june|baby|daughter|fantasy|league|draft|kicker|dad|sleep/i]],
    style: { emoji: true },
    messages: [
      [1, "19:00", "m", "fantasy draft is set for sunday 🏈🔥"],
      [1, "19:02", "t", "I'm drafting a kicker first round just to annoy you"],
      [1, "19:03", "m", "😂😂 do it coward"],
      [12, "06:15", "t", "SHE'S HERE. June Okafor, 7 lbs 2 oz"],
      [12, "06:20", "m", "BEN 😭😭🎉🎉 congrats dad!!! 👶💛"],
      [12, "06:22", "t", "she has my nose, poor kid"],
      [12, "06:23", "m", "😂 she's perfect I'm sure"],
      [20, "23:40", "t", "I have not slept in 8 days"],
      [20, "23:41", "m", "sending coffee ☕☕☕ and good vibes"],
    ],
  }),
];

// A busy month (~700 messages) with five facts buried in filler, to test
// long-context recall and the real size of a busy month's request.
export function longMonth() {
  const filler = [
    ["m", "lol"], ["t", "hahaha"], ["m", "what are you up to"], ["t", "nothing much, couch"],
    ["t", "did you eat"], ["m", "yeah leftovers"], ["m", "ugh work was long"], ["t", "same, so many meetings"],
    ["t", "omg look at this"], ["m", "😂😂"], ["m", "that's so true"], ["t", "right??"],
    ["t", "good morning"], ["m", "morning!"], ["m", "coffee first"], ["t", "always"],
    ["m", "it's so cold today"], ["t", "I'm wearing two sweaters"], ["t", "night!"], ["m", "night night"],
    ["m", "did you watch the game"], ["t", "only the second half"], ["t", "traffic was a nightmare"], ["m", "every single day"],
    ["m", "ok I'm going to bed for real"], ["t", "sure you are"], ["t", "what should I make for dinner"], ["m", "pasta. always pasta"],
    ["m", "my neighbor is drilling again"], ["t", "at 8am??"], ["t", "I need a nap"], ["m", "same honestly"],
  ];
  const planted = {
    4: [["t", "big news: I'm moving to Denver in the spring. got the transfer"], ["m", "DENVER?? I'm happy for you but sad for me"]],
    11: [["t", "I broke my wrist skateboarding. yes at 31. don't laugh"], ["m", "LENA. are you ok?? cast?"], ["t", "purple cast. sign it next time you see me"]],
    15: [["m", "severance episode tonight? same time as last week"], ["t", "yes!! I have theories about the goats"]],
    19: [["t", "I PASSED THE BAR"], ["m", "LENA!!!!! attorney Lena!!! so proud of you"]],
    25: [["m", "my sister Kate is visiting this weekend, want to get brunch with us?"], ["t", "yes! I love Kate"]],
  };
  const messages = [];
  let k = 0;
  for (let day = 1; day <= 30; day++) {
    const perDay = 20 + ((day * 7) % 9);
    for (let i = 0; i < perDay; i++) {
      const [who, text] = filler[(k++ * 7) % filler.length];
      const minute = 8 * 60 + Math.floor((i * 14 * 60) / perDay);
      const hhmm = `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}`;
      messages.push([day, hhmm, who, text]);
      if (i === Math.floor(perDay / 2) && planted[day]) {
        planted[day].forEach(([w, t], j) => messages.push([day, hhmm.replace(/\d\d$/, String(30 + j).padStart(2, "0")), w, t]));
      }
    }
  }
  return S("summary", {
    id: "lena-long-month",
    note: "~700 messages, five facts buried in small talk",
    name: "Lena Novak", them: "Lena Novak", year: 2025, month: 11,
    facts: [
      ["moving to Denver", /denver/i],
      ["broke her wrist", /wrist|cast/i],
      ["passed the bar", /bar exam|passed the bar|attorney|lawyer|\bbar\b/i],
      ["watching Severance", /severance/i],
      ["sister Kate visiting", /kate/i],
    ],
    forbidden: [["invents a breakup or wedding", /break ?up|broke up|wedding|engag/i]],
    messages,
  });
}

export const allFixtures = () => [...fixtures, longMonth()];
