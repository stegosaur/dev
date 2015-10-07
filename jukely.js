// ==UserScript==
// @name         jukely
// @namespace    http://your.homepage/
// @version      0.1
// @description  enter something useful
// @author       You
// @match        https://www.jukely.com/unlimited/shows
// @grant        none
// ==/UserScript==

function parseJukely() {
    var source = document.documentElement.innerHTML;
    var regexp = /{\".*?:null}\]}/;
    var jsondata = source.match(regexp);
    var parsed = JSON.parse(jsondata);
    var events = [];
    for (var i=0; i < parsed["events"].length; i++) {
        var headliner = parsed["events"][i]["headliner"]["name"];
        var venue = parsed["events"][i]["venue"]["name"];
        var startTime = parsed["events"][i]["starts_at"];
        var genres = parsed["events"][i]["headliner"]["genres"];
        var stat = parsed["events"][i]["status"];
        var claimLink = "<a href = https://www.jukely.com/s/" + parsed["events"][i]["parse_id"] + "/unlimited_rsvp> Claim </a>";
        message = "<h3>" + headliner + " at " + venue + " on " + startTime + " playing " + genres + " with status " + stat + " " + claimLink + "</h3>";
        document.write(message);
        events.push(message);
        //add some custom alert conditions here
        if (venue == "xxx" && stat == 2){
            alert('omglol')
        }
    }
    return events;
}

events = parseJukely();
window.stop();
window.setInterval(function () {
    window.location.reload(true);
}, 60000*(Math.floor((Math.random() * 20) + 10)) );
