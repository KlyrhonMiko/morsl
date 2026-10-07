import test from "node:test";
import assert from "node:assert/strict";
import { createVenueHandler } from "./handler.mjs";

const google = { id: "account", app_metadata: { provider: "google" } };
const request = (body = {latitude:14.55,longitude:121.02,query:"TGI Fridays Opus"}, token = "valid") =>
  new Request("https://test/nearby-venues", {method:"POST",headers:token?{Authorization: `Bearer ${token}`}:{},body:JSON.stringify(body)});
const venue = (id="opus", overrides={}) => ({id: `here:pds:place:${id}`,title:"TGI Friday's-Opus",resultType:"place",
  position:{lat:14.59261,lng:121.08071},address:{label:"Opus, Quezon City"},categories:[{id:"100-1000-0001"}],...overrides});
const create = (overrides={}) => createVenueHandler({authenticate:async()=>google,apiKey:()=>"server-key",
  consumeSearch:async()=>({allowed:true}),...overrides});

test("HERE autosuggest retains restaurant-and-mall input and returns branch coordinates",async()=>{
  const handler=create({fetchPlaces:async(url,options)=>{
    assert.equal(url.origin,"https://autosuggest.search.hereapi.com");
    assert.equal(url.pathname,"/v1/autosuggest");
    assert.equal(url.searchParams.get("q"),"TGI Fridays Opus");
    assert.equal(url.searchParams.get("at"),"14.55,121.02");
    assert.equal(url.searchParams.get("limit"),"10");
    assert.equal(url.searchParams.get("apiKey"),"server-key");
    assert.equal(url.searchParams.has("in"),false);
    assert.ok(options.signal instanceof AbortSignal);
    return Response.json({items:[venue(),venue("mall",{title:"Opus Mall",categories:[{id:"600-6100-0062"}]}),
      {resultType:"chainQuery",title:"TGI Fridays",href:"https://untrusted.test"}]});
  }});
  const response=await handler(request());
  assert.equal(response.status,200);
  assert.equal(response.headers.get("Cache-Control"),"no-store");
  assert.deepEqual(await response.json(),{places:[{id:"here:pds:place:opus",name:"TGI Friday's-Opus",address:"Opus, Quezon City",latitude:14.59261,longitude:121.08071}]});
});

test("fast-food, cafes and pubs are valid meal venues",async()=>{
  const handler=create({fetchPlaces:async()=>Response.json({items:[
    venue("mcdonalds",{title:"McDonald's",categories:[{id:"100-1000-0009"}]}),
    venue("cafe",{categories:[{id:"100-1100-0010"}]}),venue("pub",{categories:[{id:"200-2000-0011"}]})]})});
  const response=await handler(request());
  assert.equal((await response.json()).places.length,3);
});

test("invalid places, addresses and unrelated POIs cannot become confirmed locations",async()=>{
  const handler=create({fetchPlaces:async()=>Response.json({items:[null,venue("bad",{position:{lat:91,lng:121}}),
    venue("missing",{position:undefined}),venue("wrong-id",{id:""}),venue("blank",{title:" "}),
    venue("street",{resultType:"street"}),venue("unknown",{categories:[]}),venue("school",{categories:[{id:"800-8200-0173"}]}),venue()]})});
  const response=await handler(request());
  assert.equal(response.status,200);
  assert.equal((await response.json()).places.length,1);
});

test("empty input makes no provider request; empty results succeed and results cap at ten",async()=>{
  assert.deepEqual(await (await create({fetchPlaces:async()=>assert.fail("No request")})(request({latitude:14.55,longitude:121.02,query:"  "}))).json(),{places:[]});
  for(const length of [0,20]){
    const response=await create({fetchPlaces:async()=>Response.json({items:Array.from({length},(_,i)=>venue(String(i)))})})(request());
    assert.equal(response.status,200);
    assert.equal((await response.json()).places.length,Math.min(length,10));
  }
});

test("guests, invalid tokens, anonymous and non-Google accounts never call HERE",async()=>{
  for(const [user,token,status] of [[google,"",401],[null,"valid",401],[{...google,is_anonymous:true},"valid",401],
    [{id:"account",app_metadata:{provider:"email",providers:null}},"valid",403]]){
    const response=await create({authenticate:async()=>user,fetchPlaces:async()=>assert.fail("No lookup")})(request(undefined,token));
    assert.equal(response.status,status);
  }
});

test("invalid input is rejected before lookup",async()=>{
  const handler=create({fetchPlaces:async()=>assert.fail("No lookup")});
  for(const body of [null,{}, {latitude:"14",longitude:121},{latitude:91,longitude:121},
    {latitude:14,longitude:-181},{latitude:14,longitude:121,query:null},{latitude:14,longitude:121,query:"a".repeat(121)}]){
    assert.equal((await handler(request(body))).status,400);
  }
  assert.equal((await handler(new Request("https://test",{method:"POST",headers:{Authorization:"Bearer valid"},body:"broken"}))).status,400);
});

test("missing HERE key and provider failures retain manual venue entry",async()=>{
  const missing=await create({apiKey:()=>undefined,fetchPlaces:async()=>assert.fail("No lookup")})(request());
  assert.equal(missing.status,503);
  assert.match((await missing.json()).error,/Enter your own venue/);
  for(const fetchPlaces of [async()=>new Response("quota",{status:429}),async()=>Response.json({invalid:true}),
    async()=>{throw new DOMException("Timeout","TimeoutError");}]){
    const response=await create({fetchPlaces})(request());
    assert.ok([502,503].includes(response.status));
    assert.match((await response.json()).error,/Enter your own venue/);
  }
});

test("rejects other HTTP methods before authentication",async()=>{
  assert.equal((await create({authenticate:async()=>assert.fail("No auth")})(new Request("https://test"))).status,405);
});

test("quota is reserved for the authenticated user before exactly one provider call",async()=>{
  const events=[];
  const response=await create({consumeSearch:async(id)=>{events.push(id);return {allowed:true};},
    fetchPlaces:async()=>{assert.deepEqual(events,[google.id]);events.push("HERE");return Response.json({items:[]});}})(request());
  assert.equal(response.status,200);
  assert.deepEqual(events,[google.id,"HERE"]);
});

test("denied, missing and broken quota checks fail closed",async()=>{
  for(const reservation of [{allowed:false,reason:"shared_limit"},{allowed:false,reason:"disabled"},
    {allowed:false,reason:"user_daily_limit"},{allowed:false,reason:"user_minute_limit"},null,{}, {allowed:"true"}]){
    const response=await create({consumeSearch:async()=>reservation,fetchPlaces:async()=>assert.fail("No HERE call")})(request());
    assert.equal(response.status,429);
    assert.match((await response.json()).error,/enter your own venue/i);
  }
  const response=await create({consumeSearch:async()=>{throw Error("Database unavailable");},
    fetchPlaces:async()=>assert.fail("No HERE call")})(request());
  assert.equal(response.status,503);
  const defaultGuard=createVenueHandler({authenticate:async()=>google,apiKey:()=>"key",fetchPlaces:async()=>assert.fail("No HERE call")});
  assert.equal((await defaultGuard(request())).status,429);
});

test("rejected input and unauthorized requests never consume quota",async()=>{
  const consumeSearch=async()=>assert.fail("No reservation");
  for(const body of [{latitude:14,longitude:121,query:"a"},{latitude:14,longitude:121,query:" "},{}]){
    await create({consumeSearch})(request(body));
  }
  assert.equal((await create({consumeSearch})(request(undefined,""))).status,401);
  assert.equal((await create({consumeSearch,authenticate:async()=>null})(request())).status,401);
  assert.equal((await create({consumeSearch,apiKey:()=>null})(request())).status,503);
});

test("a failed provider attempt still consumes one reservation without a retry",async()=>{
  let reserved=0,calls=0;
  const response=await create({consumeSearch:async()=>{reserved++;return {allowed:true};},
    fetchPlaces:async()=>{calls++;throw Error("Timeout");}})(request());
  assert.equal(response.status,503);assert.equal(reserved,1);assert.equal(calls,1);
});
