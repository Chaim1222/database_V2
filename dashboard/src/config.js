// הגדרות חיבור למסד v2 (מפתח anon ציבורי: ההרשאות נאכפות ב-RLS ובפונקציות, ראו db/migrations/0005).
var CONFIG = {
	url: 'https://ukzijtrpchvmoxlslxpz.supabase.co',
	anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVremlqdHJwY2h2bW94bHNseHB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEyMTU1MzMsImV4cCI6MjEwNjc5MTUzM30.QCUKSOb1oOSwUPurOOhubPJFoSrQCUsClCSHEBp0BH8',
	schema: 'api',
	pageSize: 50,
	pagePattern: /\/ניהול_ייבוא$/,
	sessionKey: 'mchl2-session'
};
