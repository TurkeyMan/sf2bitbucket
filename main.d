import std.file;
import std.json;
import std.string;
import std.uri;
import std.net.curl;

// some options when running the script...
//version = MigrateMetadata; // starkos says he doesn't want the component or milestone data
version = OnlyOpenBugs;
version = MigrateComments;
version = BlankAssignee; // starkos wants the open bugs assignee's left blank


struct Milestone
{
	string name;
}

struct Component
{
	string name;
}

struct Comment
{
	string user;
	string comment;
}

struct Bug
{
	long id;

	string kind;
	string title;
	string content;
	string status;
	string priority;
	string component;
	string ver;
	string milestone;
	string responsible;

	Comment[] comments;
}

immutable string[string] kindMap;
immutable string[string] statusMap;
immutable string[string] priorityMap;
immutable string[string] userMap;

shared static this()
{
	kindMap = [
		"bugs" : "bug",
		"feature-requests" : "enhancement",
		"patches" : "proposal" ];

	statusMap = [
		"open" : "open",
		"open-accepted" : "open",
		"closed" : "resolved",
		"closed-fixed" : "resolved",
		"closed-accepted" : "resolved",
		"closed-wont-fix" : "wontfix",
		"pending" : "on hold",
		"pending-accepted" : "on hold",
		"pending-out-of-date" : "on hold",
		"closed-duplicate" : "duplicate",
		"closed-invalid" : "invalid",
		// I'm not sure about how these ones map...
		"closed-postponed" : "wontfix",
		"closed-later" : "wontfix",
		"closed-out-of-date" : "invalid",
		"closed-works-for-me" : "invalid",
		"closed-rejected" : "wontfix" ];

	priorityMap = [
		"1" : "blocker",
		"2" : "critical",
		"3" : "critical",
		"4" : "major",
		"5" : "major",
		"6" : "major",
		"7" : "minor",
		"8" : "minor",
		"9" : "trivial" ];

	userMap = [
		"nobody" : null,
		"starkos" : "starkos",
		"jason379" : "starkos" ];
}

// helper to return a null string if the JSONValue is NULL, rather than throwing.
string asStr(JSONValue v)
{
	if(v.type != JSON_TYPE.NULL)
		return v.str;
	return null;
}


// runtime data...

string login, password;
string repo;
string[] sources;

string issuesApi;

Milestone[string] milestones;
Component[string] components;

string[string] newMilestones;
string[string] newComponents;

Bug[] failed;


// functions

void parseCommandLine(string[] cmdline)
{
	enum Expecting { unknown, login, password, repo }

	Expecting next = Expecting.unknown;
	foreach(c; cmdline[1..$])
	{
		final switch(next)
		{
			case Expecting.unknown:
				if(c == "-l")
					next = Expecting.login;
				else if(c == "-p")
					next = Expecting.password;
				else if(c == "-r")
					next = Expecting.repo;
				else if(c.length > 2 && c[0..2] == "-l")
					login = c[2..$];
				else if(c.length > 2 && c[0..2] == "-p")
					password = c[2..$];
				else if(c.length > 2 && c[0..2] == "-r")
					repo = c[2..$];
				else
					sources ~= c;
				break;
			case Expecting.login:
				login = c;
				break;
			case Expecting.password:
				password = c;
				break;
			case Expecting.repo:
				repo = c;
				// TODO: validate repo in proper format: "account/repository"
				break;
		}
		next = Expecting.unknown;
	}

	assert(login, "No login supplied, use: -l username");
	assert(password, "No password supplied, use: -p password");
	assert(repo, "No repository supplied, use: -r account/repository");
	assert(sources, "No source files supplied.");
}

void fetchMetadata()
{
	// read data from the existing repo
	string response = get(issuesApi ~ "/components");
	if(response)
	{
		auto json = parseJSON(response);
		foreach(c; json.array)
		{
			string component = c.object["name"].str;
			components[component] = Component(component);
		}
	}

	response = get(issuesApi ~ "/milestones");
	if(response)
	{
		auto json = parseJSON(response);
		foreach(m; json.array)
		{
			string milestone = m.object["name"].str;
			milestones[milestone] = Milestone(milestone);
		}
	}
}

void parseMetadata(ref Bug newBug, JSONValue bug)
{
	auto custom = bug["custom_fields"].object;
	if(custom)
	{
		newBug.milestone = "_milestone" in custom ? custom["_milestone"].asStr : null;
		if(newBug.milestone && newBug.milestone !in milestones)
		{
			newMilestones[newBug.milestone] = newBug.milestone;
			milestones[newBug.milestone] = Milestone(newBug.milestone);
		}
	}

	// extract labels
	auto labels = bug["labels"].array;
	if(labels.length >= 1)
		newBug.component = labels[0].str;
	foreach(l; labels)
	{
		string label = l.str;
		if(label !in components)
		{
			newComponents[label] = label;
			components[label] = Component(label);
		}
	}
}

void postMetadata()
{
	// post new milestone
	foreach(m; newMilestones)
	{
		std.stdio.writeln("Submit milestone: ", m);
		post(issuesApi ~ "/milestones", "name=" ~ m);
	}

	// post new component
	foreach(c; newComponents)
	{
		std.stdio.writeln("Submit component: ", c);
		post(issuesApi ~ "/components", "name=" ~ encode(c));
	}

	// do something with the version?
//	newBug.ver;
}

Bug parseBug(JSONValue bug, string kind)
{
	Bug newBug;

	newBug.kind = kind;
	newBug.title = translate(bug["summary"].asStr);
	newBug.content = std.string.format("@%s:\n\n%s", bug["reported_by"].asStr, translate(bug["description"].asStr));

	string status = bug["status"].asStr;
	newBug.status = status && status in statusMap ? statusMap[status] : "new";

	assert(newBug.status != "new");

	auto custom = bug["custom_fields"].object;
	if(custom)
	{
		string priority = "_priority" in custom ? custom["_priority"].asStr : null;
		newBug.priority = priority in priorityMap ? priorityMap[priority] : null;
	}

	version(MigrateMetadata)
		parseMetadata(newBug, bug);

	// parse assigned_to
	string assigned = bug["assigned_to"].asStr;
	if(assigned)
		newBug.responsible = assigned in userMap ? userMap[assigned] : null;

	// parse discussion
	version(MigrateComments)
		parseComments(bug, newBug);

	// starkos wants open bugs assignee left blank...
	version(BlankAssignee)
	{
		if(newBug.status == "open" && newBug.responsible)
			newBug.responsible = null;
	}

	foreach(attachment; bug["attachments"].array)
	{
		string url = attachment["url"].str;
		newBug.content ~= "\n\nAttachment: " ~ url;
	}

	return newBug;
}

void postBug(ref Bug bug)
{
	// build POST string
	char[] data;
	data ~= "kind=" ~ bug.kind;
	data ~= "&title=" ~ encode(bug.title);
	if(bug.content)
		data ~= "&content=" ~ encode(bug.content);
	if(bug.status)
		data ~= "&status=" ~ bug.status;
	if(bug.priority)
		data ~= "&priority=" ~ bug.priority;
	if(bug.component)
		data ~= "&component=" ~ encode(bug.component);
	if(bug.ver)
		data ~= "&version=" ~ bug.ver;
	if(bug.status)
		data ~= "&status=" ~ bug.status;
	if(bug.milestone)
		data ~= "&milestone=" ~ bug.milestone;
	if(bug.responsible)
		data ~= "&responsible=" ~ bug.responsible;

	version(OnlyOpenBugs)
	{
		if(bug.status != "open" && bug.status != "on hold")
			return;
	}

	std.stdio.writeln("Posting issue: ", bug.title);

	try
	{
		string response = post(issuesApi, data);
		auto json = parseJSON(response);

		// if it posted successfully, we can try and add the comments
		if(json.type != JSON_TYPE.NULL)
		{
			bug.id = json["local_id"].integer;

			version(MigrateComments)
				postComments(bug);
		}
		else
		{
			// bitbucket didn't like it...
			failed ~= bug;
		}
	}
	catch
	{
		// unexpected failure?
		failed ~= bug;
	}
}

void parseComments(JSONValue bug, ref Bug newBug)
{
	auto thread = bug["discussion_thread"].object;
	if(thread)
	{
		foreach(post; thread["posts"].array)
		{
			Comment c;
			string user = post["author"].asStr;
			c.user = user in userMap ? userMap[user] : user;
			c.comment = std.string.format("@%s wrote:\n\n%s", c.user, translate(post["text"].asStr));

			foreach(attachment; post["attachments"].array)
			{
				string url = attachment["url"].str;
				c.comment ~= "\n\nAttachment: " ~ url;
			}
			string s = c.comment;

			newBug.comments ~= c;
		}
	}
}

void postComments(ref Bug bug)
{
	foreach(comment; bug.comments)
	{
		string response = post(issuesApi ~ "/" ~ std.conv.to!string(bug.id) ~ "/comments", "content=" ~ encode(comment.comment));

		// check response...
	}
}


int main(string[] argv)
{
	parseCommandLine(argv);

	issuesApi = "https://bitbucket.org/api/1.0/repositories/" ~ repo ~ "/issues";

	version(MigrateMetadata)
		fetchMetadata();

	// parse the SF bugs
	Bug[] bugs;
	foreach(source; sources)
	{
		auto bytes = cast(string)read(source);
		auto json = parseJSON(bytes);

		auto dot = source.indexOf('.');
		string collection = dot != -1 ? source[0..dot] : null;
		string kind = collection in kindMap ? kindMap[collection] : "bug";

		// translate to BitBucket
		foreach(bug; json["tickets"].array)
			bugs ~= parseBug(bug, kind);
	}

	version(MigrateMetadata)
		postMetadata();

	// post to bitbucket
	foreach(i, bug; bugs)
		postBug(bug);

	// log the ones that failed...
	foreach(f; failed)
		std.stdio.writeln("Failed: ", f.title);

    return 0;
}


// *** helpers ***

// SourceForge json has some really weird escaping going on... we'll try and translare the strings back to normal...
struct Translation { string k; string v; }

Translation translationTable[] = [
	Translation("&amp;lt;", "<"),
	Translation("&amp;gt;", ">"),
	Translation("&amp;quot;", "\""),
	Translation("&amp;amp;", "&"),
	Translation("&amp;apos;", "'"),
	Translation("&lt;", "<"),
	Translation("&lt;", ">"),
	Translation("\\(", "("),
	Translation("\\)", ")"),
	Translation("\\[", "["),
	Translation("\\]", "]"),
	Translation("\\{", "{"),
	Translation("\\}", "}"),
	Translation("\\_", "_") ];

string translate(string str)
{
	char[] buffer;
	outer: for(size_t i = 0; i < str.length; )
	{
		foreach(t; translationTable)
		{
			size_t len = t.k.length;
			if(str[i .. $].length >= len && str[i .. i + len] == t.k)
			{
				buffer ~= t.v;
				i += len;
				continue outer;
			}
		}
		buffer ~= str[i];
		++i;
	}
	return buffer.idup;
}

// curl helpers
string get(string url)
{
	string buffer;
	auto http = HTTP(url);
	http.setAuthentication(login, password);
	http.caInfo = r"C:\Program Files (x86)\Git\bin\curl-ca-bundle.crt";
	http.onReceive = (ubyte[] data) { buffer ~= data; return data.length; };
	http.perform();
	return buffer;
}

string post(string url, const char[] data)
{
	string buffer;
	auto http = HTTP(url);
	http.setAuthentication(login, password);
	http.caInfo = r"C:\Program Files (x86)\Git\bin\curl-ca-bundle.crt";
	http.onReceive = (ubyte[] data) { buffer ~= data; return data.length; };
	http.postData = data;
	http.perform();
	return buffer;
}
