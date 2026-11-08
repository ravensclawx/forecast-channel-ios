/// JavaScript injected into every manual document. It stands in for the parts of the original that live outside the
/// HTML: the `vcJavaScriptExt` plug-in (vcJavaScriptExt.dll registered by fn_80081954 / fn_80081B18), the pointer →
/// WWWSurfaceMouseEvt path (fn_80082B64) and the wheel scroll + display smoothing (fn_80082D48 / fn_800809B8).
enum ManualScript {
    /// Runs in every frame at document start.
    static func ext(fontURL: String, portrait: Bool = false) -> String {
        """
        (function(){
          var post = function(m){ try { window.webkit.messageHandlers.fc.postMessage(m); } catch(e){} };
          // fn_80081B18: FadeIn → fn_80081F78 (transition 0), FocusSound → fn_80081FB4, LeftScroll → fn_8008200C
          // (transition 1), RightScroll → fn_80082060 (transition 2), SelectSound → fn_800820B4, WriteFlag → fn_800820C4.
          window.vcJavaScriptExt = function(){
            return {
              FadeIn: function(){ post({k:'trans', d:0}); },
              FocusSound: function(){ post({k:'focus'}); },
              LeftScroll: function(){ post({k:'trans', d:1}); },
              RightScroll: function(){ post({k:'trans', d:2}); },
              SelectSound: function(){ post({k:'select'}); },
              WriteFlag: function(){}
            };
          };
          // Opera 8/9 (like IE) let getElementById fall back to name="" — startup's rollovers (chimg('menuN')) rely on it.
          var gid = Document.prototype.getElementById;
          Document.prototype.getElementById = function(id){
            var e = gid.call(this, id);
            if (!e && id) { var n = this.getElementsByName(id); if (n.length) e = n[0]; }
            return e;
          };
          // WWWSurfaceAddFont(WiiNTLG-Regular.ttc): the pages name "Wii NTLG PGothic Regular".
          var addFont = function(){
            if (!document.head || document.getElementById('__fcfont')) return;
            var s = document.createElement('style'); s.id = '__fcfont';
            s.textContent = '@font-face{font-family:"Wii NTLG PGothic Regular";src:url("\(fontURL)") format("truetype");}' +
                            'html,body{-webkit-user-select:none;cursor:none;}';
            document.head.appendChild(s);
          };
          document.addEventListener('DOMContentLoaded', addFont);
          if (document.readyState !== 'loading') addFont();
          // iPhone portrait: the bottom bar's ✚ Scroll / Ⓐ Select hints have no buttons to refer to (the finger scrolls
          // and taps); they are hidden, and "⌂: Close" closes the manual when tapped.
          var touchBar = function(){
            if (!\(portrait ? "true" : "false")) return;
            var icon = document.querySelector('img[src*="index_bottom_icon_3"]');
            if (!icon || document.__fcBar) return;
            document.__fcBar = true;
            var row = icon.closest('tr'); if (!row) return;
            var cells = row.cells;
            for (var i = 0; i < cells.length - 2; i++) cells[i].style.visibility = 'hidden';
            for (var j = cells.length - 2; j < cells.length; j++) {
              cells[j].style.cursor = 'pointer';
              cells[j].addEventListener('click', function(){ post({k:'close'}); });
            }
          };
          document.addEventListener('DOMContentLoaded', touchBar);
          if (document.readyState !== 'loading') touchBar();
          // iPhone portrait: a single-page document (the chapters are laid out for the 456-px surface) is centred in
          // the taller browser instead of leaving the lower half empty. Framesets fill the height by themselves.
          var centre = function(){
            if (!\(portrait ? "true" : "false") || window.top !== window || !document.body) return;
            if (document.getElementsByTagName('frameset').length) return;
            document.body.style.marginTop = '0px';
            var bottom = 0, all = document.body.getElementsByTagName('*');
            for (var i = 0; i < all.length; i++) { var r = all[i].getBoundingClientRect(); if (r.height > 0 && r.bottom > bottom) bottom = r.bottom; }
            var free = window.innerHeight - (bottom + window.scrollY);
            if (free > 2) document.body.style.marginTop = Math.floor(free / 2) + 'px';
          };
          window.addEventListener('load', centre);
        })();
        """
    }

    /// Runs in the top document only: pointer events into the right frame, wheel scrolling with the original's
    /// display smoothing, and state queries for the Swift side.
    static let host = """
    (function(){
      if (window.__fc) return;
      var fc = { last: null, down: null, wins: [] };
      // Opera hit-tests through the frameset: descend FRAME/IFRAME elements to the innermost document.
      fc.hit = function(x, y){
        var win = window, doc = document, el = null;
        for (var i = 0; i < 8; i++) {
          el = doc.elementFromPoint(x, y);
          if (!el) break;
          var t = el.tagName;
          if ((t === 'FRAME' || t === 'IFRAME') && el.contentWindow && el.contentDocument) {
            var r = el.getBoundingClientRect(); x -= r.left; y -= r.top;
            win = el.contentWindow; doc = el.contentDocument; continue;
          }
          break;
        }
        return { el: el, win: win, doc: doc, x: x, y: y };
      };
      var fire = function(el, type, h, rel){
        if (!el) return true;
        var ev = new h.win.MouseEvent(type, { bubbles: true, cancelable: true, view: h.win, clientX: h.x, clientY: h.y,
                                              button: 0, buttons: type === 'mousedown' ? 1 : 0, relatedTarget: rel || null });
        return el.dispatchEvent(ev);
      };
      // fn_80082B64 mode 0: WWWSurfaceMouseEvt(move)
      fc.move = function(x, y){
        var h = fc.hit(x, y), el = h.el;
        if (el !== (fc.last && fc.last.el)) {
          if (fc.last && fc.last.el && fc.last.el.isConnected) fire(fc.last.el, 'mouseout', fc.last, el);
          if (el) fire(el, 'mouseover', h, fc.last ? fc.last.el : null);
        }
        if (el) fire(el, 'mousemove', h);
        fc.last = h;
      };
      // modes 1/2: button down / up (Opera turns a down+up on the same element into a click).
      fc.press = function(x, y){ var h = fc.hit(x, y); fc.down = h; fire(h.el, 'mousedown', h); };
      fc.release = function(x, y){
        var h = fc.hit(x, y); fire(h.el, 'mouseup', h);
        if (fc.down && h.el && fc.down.el === h.el) {
          // activation (links, onClick) like a real click
          var el = h.el;
          if (fire(el, 'click', h)) {
            var a = el.closest ? el.closest('a[href]') : null;
            if (a && !a.__fcNav) { /* default action is performed by WebKit for the dispatched click */ }
          }
        }
        fc.down = null;
      };
      // fn_80082D48 → WWWSurfaceWheelEvt(±1) on the document under the pointer; Opera scrolls the target at once,
      // the compositor (fn_800809B8) then chases it: v += 2 per frame up to 40, braking with v = 2(√(d + ¼) − ½).
      fc.wheel = function(x, y, dir, step){
        var h = fc.hit(x, y), w = h.win, d = h.doc;
        var se = d.scrollingElement || d.documentElement;
        var max = Math.max(0, se.scrollHeight - w.innerHeight);
        if (max <= 0) return;
        if (w.__fcPos === undefined) { w.__fcPos = w.scrollY; w.__fcV = 0; w.__fcT = w.scrollY; }
        w.__fcT = Math.max(0, Math.min(max, w.__fcT + dir * step));
        if (fc.wins.indexOf(w) < 0) fc.wins.push(w);
      };
      fc.step = function(){
        var busy = false;
        fc.wins = fc.wins.filter(function(w){ try { return !w.closed && w.document; } catch(e) { return false; } });
        fc.wins.forEach(function(w){
          var dd = w.__fcT - w.__fcPos, v = w.__fcV;
          if (dd > 1) {
            if (!(0.5 * (v * (v * 0.5 + 1)) < dd)) v = 2 * (Math.sqrt(2 * dd * 0.5 + 0.25) - 0.5);
            else { v += 2; if (v > 40) v = 40; }
            w.__fcPos += v; busy = true;
          } else if (dd < -1) {
            if (!(-0.5 * (v * (v * 0.5 - 1)) > dd)) v = 2 * (0.5 - Math.sqrt(-(2 * dd * 0.5 - 0.25)));
            else { v -= 2; if (v < -40) v = -40; }
            w.__fcPos += v; busy = true;
          } else { v = 0; w.__fcPos = w.__fcT; }
          w.__fcV = v;
          w.scrollTo(0, Math.floor(0.5 + w.__fcPos));
        });
        return busy;
      };
      // iPhone: move the scrollable frame under (x, y) with the finger (dy > 0 = finger moved down = content down).
      fc.drag = function(x, y, dy){
        var h = fc.hit(x, y), w = h.win, d = h.doc;
        var se = d.scrollingElement || d.documentElement;
        var max = Math.max(0, se.scrollHeight - w.innerHeight);
        if (max <= 0) return;
        var p = (w.__fcPos === undefined) ? w.scrollY : w.__fcPos;
        p = Math.max(0, Math.min(max, p - dy));
        w.__fcPos = p; w.__fcT = p; w.__fcV = 0;
        if (fc.wins.indexOf(w) < 0) fc.wins.push(w);
        w.scrollTo(0, Math.floor(0.5 + p));
      };
      fc.reset = function(){ fc.last = null; fc.down = null; fc.wins = []; };
      window.__fc = fc;
    })();
    """
}
