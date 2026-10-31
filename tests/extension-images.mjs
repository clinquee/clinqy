// Run production image discovery against a deterministic DOM fixture, with no user browser.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
function img(url, alt, opts={}) {
  const rect={width:200,height:160,left:0,right:200,top:20,bottom:180,...opts.rect};
  return {currentSrc:url,src:url,alt,title:'',naturalWidth:200,naturalHeight:160,...opts,
    getBoundingClientRect(){return rect;},closest(){return opts.chrome ? {} : null;},
    getAttribute(key){return opts.attrs?.[key] || null;}};
}
const items=[img('https://site.test/icon.png','Icon',{rect:{width:16,height:16}}),
  img('https://site.test/first.webp','First article image'),
  img('https://site.test/first.webp','Duplicate'),
  img('https://site.test/ad.png','Ad',{chrome:true}),
  img('https://site.test/hidden.png','Hidden',{hidden:true}),
  img('https://site.test/pixel.gif','Lazy image',{naturalWidth:1,naturalHeight:1,attrs:{'data-src':'/real.png'}}),
  img('https://site.test/below.png','Below',{rect:{top:2000,bottom:2160}}),
  img('javascript:alert(1)','Bad')];
const root={querySelectorAll(){return items;}};
class MutationObserver { disconnect() {} takeRecords() { return []; } observe() {} }
const context=vm.createContext({window:{},MutationObserver,crypto:{randomUUID:()=> 'doc'},URL,Map,Set,WeakMap,
  document:{body:root,baseURI:'https://site.test/article',title:'Fixture',querySelector(){return root;}},
  location:{href:'https://site.test/article'},innerHeight:900,innerWidth:1440,
  getComputedStyle(el){return {display:el.hidden?'none':'block',visibility:'visible',opacity:'1'};}});
vm.runInContext(fs.readFileSync(new URL('../extension/page.js',import.meta.url),'utf8'),context);
const result=context.window.__clinqy.images();
assert.equal(result.images.length,3);
assert.equal(result.images[0].url,'https://site.test/first.webp');
assert.equal(result.images[0].alt,'First article image');
assert.equal(result.images[1].url,'https://site.test/real.png');
assert.equal(result.images[1].loaded,false);
assert.equal(result.images[1].rect,null);
assert.equal(result.images[2].visible,false);
assert.ok(result.images.every(i=>i.page==='https://site.test/article'));
console.log('PASS actual currentSrc, lazy sources, article order, dimensions and source provenance');
console.log('PASS navigation/ad/tiny/hidden/duplicate/unsafe sources excluded without changing focus');
