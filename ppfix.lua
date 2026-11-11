local pr_kick = false
function onReceiveRPC(id, bs)
	if id == 139 and not pr_kick then
		pr_kick = true
		reconnect(5000)
	end
end